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
cmd.exe /c "zig build test check console --summary all --cache-dir %LOCALAPPDATA%\zig-snek-cache"
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
- **Paths.** One rule, `platform.files.join` (and a copy in `cfg`): a path shows the way it
  was written, and new parts take the separator it already uses (`./snek.toml`,
  `conf/shared/base.yaml`, `C:\x\snek.toml`). Used by `cfg` sources and includes,
  `findFile`, `snek tui md`, and `examples/repos`; tests of native paths use `sep_str`.
- **`term.Pty` reads never ended on Windows**: the pseudo console keeps its output open
  after the program exits. A thread now closes it when the program ends, so `snek cli
  explain`, `record`, and `tui serve` see the end as on POSIX.
- **`PAGER` with a Windows path** lost its backslashes (split by POSIX shell rules); it is
  split by `CommandLineToArgvW`'s rules on Windows now.
- **`snek cli record` with `Set Shell cmd`** ran the user's AutoRun commands (clink); `cmd`
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
  Ctrl-C, Ctrl-Break, and console close (console case `spin`); WebAuthn assertions through
  Windows Hello, `platform.windows_hello`, the way to a FIDO key on Windows.
- **Tests that skipped Windows now run there:** `process.which` (Windows rules), `capture`
  (output, status, cwd, environment, limits, timeout kill), `stream`, `editText`, plugins
  on `PATH` (`cli`, `examples/kv`), help through the pager, `tui spin`'s `runChild`, raw
  mode on a non-terminal, `Pty` on ConPTY, `cli explain` and `cli record`, and `sandbox`
  links where Windows allows them. Test-only fixes: a TOML literal string for a temp path,
  file timestamps set through the file (`Dir.setTimestamps` is a TODO panic in 0.17), the
  `pwsh` alias passed as a plain argument, `complete.ps1` ending lines with LF.
- **`snek tui serve` with a Windows program**, tried by hand: over SSH on pipes (`snek
  platform ssh run`) and on a pseudo console (OpenSSH's `ssh -tt`, the session ending when
  the program does), and `--web` in a browser, typing into `cmd.exe`.
- **`snek tui image -p auto`**: Windows Terminal 1.24 answers the query with sixel (and
  `WT_SESSION` says the same); the classic console host answers without graphics, so it
  gets `mosaic`. Both in real windows, through the console case `query`.
- **`examples/repos` by hand**, against real git (2.55, Git for Windows): `setup` at a
  console, typing a root with backslashes (written to TOML escaped); `list` with a name
  holding a space and a nested `work/api`; `fetch` (ahead and behind a local remote); the
  TUI under ConPTY (filter, quit); and `ui --web` in a browser.
- **The release `.zip`**: built as `release.yml` does (`ReleaseSafe`, `x86_64-windows`),
  zipped, and extracted by `update.extractExecutable` to the same bytes. (Zipped here with
  Windows' `tar -a`; CI uses Info-ZIP.)

## Left

| What | State |
|---|---|
| The first CI run | `ci.yml` runs `zig build test` and `zig build console` on `windows-latest`; it has never run. Locally everything above passes |
| Windows Hello for real | `windows_hello.assert` is tested for layout, options, and errors, and finds the API; no assertion has been made (it opens the system dialog). No command uses it yet |
| ssh-agent against OpenSSH's agent | tested against a fake agent on a named pipe. The real one needs its service running (here it is disabled), and `ssh-agent.exe -d` will not run unelevated ("cannot create agent root reg key") |
| `sandbox` with links | the test skips without the privilege or Developer Mode, which this machine lacks |
| `platform.web.Server` test trace | once, a `CONNECTION_RESET` stack trace in Debug; the test passes. Not reproduced in eight runs, nor by probes of read, write, accept, and shutdown after a reset (below) |
| Ctrl+Z suspend | nothing to do: Windows consoles have no job control |
| A cached example that crashes with no output | once, `zig build examples` ran `first-app.exe` and `tasks.exe` from the cache, and they crashed silently (status 5, or an access violation) on every run, while byte-identical copies, even in the same folder, ran fine. Windows was mapping a stale image of those files; copying the same bytes over each fixed it. Not snek's code. If it comes back, replace the file, or delete that `o/` folder |
| ARM64 Windows | compiled by `check`; `ci.yml` runs the tests and `console` on `windows-11-arm`, which has never run either |

## Upstream reports (drafted, not filed)

**`Io.Batch.awaitConcurrent` breaks the batch when it returns `ConcurrencyUnavailable` on
Windows.** `batchDrainSubmittedWindows` turns the submission into a pending operation
before it finds that the handle is synchronous; the `errdefer` puts `submitted.head` back,
but the storage is no longer a submission. Run at a console:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buffer: [16]u8 = undefined;
    var data = [1][]u8{&buffer};
    var storage: [1]std.Io.Operation.Storage = undefined;
    var batch: std.Io.Batch = .init(&storage);
    defer batch.cancel(io);
    batch.addAt(0, .{ .file_read_streaming = .{ .file = .stdin(), .data = &data } });
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } };
    batch.awaitConcurrent(io, timeout) catch |err| switch (err) {
        error.ConcurrencyUnavailable => try batch.awaitAsync(io),
        else => |e| return e,
    };
}
```

Debug: `panic: access of union field 'submission' while field 'unused' is active` in
`batchDrainSubmittedWindows` (`Threaded.zig:3089`), called from `batchAwaitAsync`.

**`Io.net` reports `error.Unexpected` on Windows for connections that ended**, with a
stack trace in Debug. Both reproduce every time:

- A read cut off by the socket's own `shutdown`: `PIPE_DISCONNECTED` (`0xc00000b0`);
  `netReadWindows` maps only `CONNECTION_RESET` and `REMOTE_DISCONNECT`.
- A write after the peer reset the connection: `LOCAL_DISCONNECT` (`0xc000013b`) from
  `netWriteWindows`. To reproduce, a client writes bytes the server never reads and
  closes, which makes Windows reset; the server then writes and flushes.

`netAcceptWindows` and `netShutdownWindows` send every status but `INSUFFICIENT_RESOURCES`
to `unexpectedStatus`, which may be where the `CONNECTION_RESET` seen once in the
`platform.web.Server` tests came from; a probe of each after a reset did not trigger it.

**`Dir.setTimestamps` panics on Windows** ("TODO implement dirSetTimestamps windows"),
while `File.setTimestamps` works.
