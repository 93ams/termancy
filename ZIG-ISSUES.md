# Zig issues found while porting snek to Windows

Five problems in Zig 0.17.0's standard library, met while making snek run on Windows. Each
is written up as an issue for [Zig's tracker](https://codeberg.org/ziglang/zig/issues), ready
to file. None is filed yet.

All of them were reproduced on 2026-10-17 with:

- Zig 0.17.0 (release), `x86_64-windows`, Debug
- Windows 11 Pro 25H2 (build 26200)
- `std.Io.Threaded`, the `Io` that `std.process.Init` provides

The Linux comparisons use the same Zig 0.17.0 on `x86_64-linux` (WSL 2). Line numbers refer
to `lib/std/Io/Threaded.zig` in the 0.17.0 release.

| # | Title | Filing | Severity |
|---|---|---|---|
| 1 | `Io.Batch` is corrupted when `awaitConcurrent` returns `ConcurrencyUnavailable` on Windows | new issue | panic in safe modes; illegal behaviour in `ReleaseFast` |
| 2 | Reading a socket after its own `shutdown` returns `error.Unexpected` on Windows | comment on [#31956](https://codeberg.org/ziglang/zig/issues/31956) | wrong error, stack trace in Debug |
| 3 | Writing to a reset connection returns `error.Unexpected` on Windows | comment on [#31956](https://codeberg.org/ziglang/zig/issues/31956) | wrong error, stack trace in Debug |
| 4 | `Stream.shutdown` does not wake a read blocked on the same socket on Windows | new issue | hang |
| 5 | `Dir.setTimestamps` panics on Windows | new issue | panic |

Searched for duplicates on 2026-10-17. Related but different:
[#36190](https://codeberg.org/ziglang/zig/issues/36190) (another `awaitConcurrent`
bookkeeping bug, on the net receive fast path),
[#36047](https://codeberg.org/ziglang/zig/issues/36047) (`ConcurrencyUnavailable` for UDP
receive with a timeout, whose obvious workaround runs into issue 1), and
[#36632](https://codeberg.org/ziglang/zig/issues/36632) (closed; mapped `REMOTE_DISCONNECT`
and `IO_TIMEOUT` in the same functions as issues 2 and 3).

---

## 1. `Io.Batch` is corrupted when `awaitConcurrent` returns `ConcurrencyUnavailable` on Windows

**Labels:** bug, lib/std, os-windows

### Description

On Windows, `Io.Batch.awaitConcurrent` returns `error.ConcurrencyUnavailable` when an
operation cannot be waited on concurrently, for example a read from a synchronous handle
such as a console. Before it returns, it has already drained that operation out of the
batch in a way that leaves the batch's lists inconsistent. The documented fallback, calling
`awaitAsync` on the same batch, then reads a storage slot as the wrong union field and
panics.

### Steps to reproduce

1. Save as `batch.zig`:

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
           // Fall back to waiting without concurrency.
           error.ConcurrencyUnavailable => try batch.awaitAsync(io),
           else => |e| return e,
       };
   }
   ```

2. Build it with `zig build-exe batch.zig`, then run `batch.exe` in a console window
   (Windows Terminal or conhost), so that standard input is a synchronous console handle.

### Expected behaviour

`awaitConcurrent` returns `error.ConcurrencyUnavailable` and leaves the batch as it was, so
`awaitAsync` performs the read: the program waits for a line of input.

### Actual behaviour

```
thread 24960 panic: access of union field 'submission' while field 'unused' is active
error return context:
lib\std\Io\Threaded.zig:3138:38: in batchDrainSubmittedWindows
                    if (concurrency) return error.ConcurrencyUnavailable;
lib\std\Io\Threaded.zig:2763:9: in batchAwaitConcurrent
        try batchDrainSubmittedWindows(t, b, true);

stack trace:
lib\std\Io\Threaded.zig:3089:35: in batchDrainSubmittedWindows
        const submission = storage.submission;
lib\std\Io\Threaded.zig:2606:35: in batchAwaitAsync
        batchDrainSubmittedWindows(t, b, false) catch |err| switch (err) {
batch.zig:15:61: in main
        error.ConcurrencyUnavailable => try batch.awaitAsync(io),
```

### Cause

In `batchDrainSubmittedWindows` (line 3084), each submitted operation goes through these
steps in order:

1. Its storage slot is overwritten from `.submission` to `.pending` and appended to the
   pending list.
2. An `errdefer` is registered that completes the operation as `CANCELLED` through
   `batchApc`, which moves the slot to the **unused** list.
3. Only then does the operation's branch check `if (concurrency) return
   error.ConcurrencyUnavailable` (lines 3138, 3194, 3249, 3280, 3287, 3294, 3304).

On that return, the step-2 `errdefer` puts the slot on the unused list. Then the outer
`errdefer b.submitted.head = index` points the submitted list back at the **same slot**. The
slot is now on two lists. The next drain reads `storage.submission` from a slot that holds
`.unused`. The operation the caller added is also lost: it is neither performed nor
reported.

### Impact

- It affects every operation kind that can return `ConcurrencyUnavailable` on Windows:
  `file_read_streaming` and `file_write_streaming` on synchronous handles,
  `device_io_control`, and all four net operations.
- The fallback the error invites, `awaitAsync`, panics in Debug and ReleaseSafe and is
  illegal behaviour in ReleaseFast. The workaround suggested in
  [#36047](https://codeberg.org/ziglang/zig/issues/36047) runs into this.
- Even code that never retries the batch loses the operation silently.
- Any portable code that reads console input through a batch with a timeout is affected.
  snek works around it on Windows by waiting on the console handle itself instead of
  through `Io.Batch`.

### Suggested fix

Decide whether the operation can run concurrently **before** converting its slot to
`.pending`. Alternatively, on `ConcurrencyUnavailable` restore the slot to `.submission`,
take it off the pending list, and skip the cancelling `errdefer`. Either way the batch is
left exactly as the caller built it.

---

## 2. Reading a socket after its own `shutdown` returns `error.Unexpected` on Windows

**Filing:** as a comment on [#31956](https://codeberg.org/ziglang/zig/issues/31956)
("std.Io.Threaded on Windows leaves several common NTSTATUS values unmapped in socket
paths"), which does not list this status.

### Description

When a program calls `Stream.shutdown(io, .both)` or `.recv` and then reads from the same
stream, `netReadWindows` gets `STATUS_PIPE_DISCONNECTED` (`0xC00000B0`). It is not mapped,
so it reaches `windows.unexpectedStatus` and comes back as `error.Unexpected`, with a stack
trace in Debug. On Linux the same read returns end of stream.

### Steps to reproduce

1. Save as `net_read_after.zig`:

   ```zig
   const std = @import("std");
   const net = std.Io.net;

   pub fn main(init: std.process.Init) !void {
       const io = init.io;
       const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
       var server = try loopback.listen(io, .{});
       defer server.deinit(io);
       const client = try server.socket.address.connect(io, .{ .mode = .stream });
       defer client.close(io);
       const conn = try server.accept(io);
       defer conn.close(io);

       try conn.shutdown(io, .both); // `.recv` behaves the same
       var buffer: [64]u8 = undefined;
       var reader = conn.reader(io, &buffer);
       _ = reader.interface.takeByte() catch {};
       std.debug.print("read error: {any}\n", .{reader.err});
   }
   ```

2. Run it with `zig run net_read_after.zig`.

### Expected behaviour

`read error: null`: the reader reports end of stream, as it does on Linux.

### Actual behaviour

```
error.Unexpected NTSTATUS=0xc00000b0 (PIPE_DISCONNECTED)
lib\std\Io\Threaded.zig:13014:57: in netReadWindows
        else => |status| return windows.unexpectedStatus(status),
lib\std\Io\Threaded.zig:12889:61: in netRead
...
read error: error.Unexpected
```

A read after the **peer** closes is fine on Windows (end of stream). Only the local
shutdown case fails.

### Impact

Shutting a connection down and then draining it is the normal way to end a session.
Callers that treat `error.Unexpected` as a real failure log an error for every connection
that closes cleanly. snek's SSH transport has to treat this one `Unexpected` as a hang-up on
Windows.

### Suggested fix

In `netReadWindows`, map `.PIPE_DISCONNECTED` to a return of `0` (end of stream), matching
`recv` after `SHUT_RD` on POSIX.

---

## 3. Writing to a reset connection returns `error.Unexpected` on Windows

**Filing:** as a comment on [#31956](https://codeberg.org/ziglang/zig/issues/31956), which
lists `LOCAL_DISCONNECT` for `netReadWindows` but not for `netWriteWindows`.

### Description

After the peer resets a TCP connection, a write on it fails in `netWriteWindows` with
`STATUS_LOCAL_DISCONNECT` (`0xC000013B`). It is not mapped, so the writer reports
`error.Unexpected`, with a stack trace in Debug, instead of `error.ConnectionResetByPeer`.

### Steps to reproduce

1. Save as `net_write_reset.zig`:

   ```zig
   const std = @import("std");
   const net = std.Io.net;

   pub fn main(init: std.process.Init) !void {
       const io = init.io;
       const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
       var server = try loopback.listen(io, .{});
       defer server.deinit(io);
       const client = try server.socket.address.connect(io, .{ .mode = .stream });
       const conn = try server.accept(io);
       defer conn.close(io);

       // The client sends bytes the server never reads, then closes; the server's
       // writes after that meet a reset connection.
       var client_buffer: [64]u8 = undefined;
       var client_writer = client.writer(io, &client_buffer);
       try client_writer.interface.writeAll("unread");
       try client_writer.interface.flush();
       try io.sleep(.fromMilliseconds(100), .awake);
       client.close(io);
       try io.sleep(.fromMilliseconds(200), .awake);

       var buffer: [64]u8 = undefined;
       var writer = conn.writer(io, &buffer);
       for (0..3) |_| {
           writer.interface.writeAll("hello") catch {};
           writer.interface.flush() catch {};
           if (writer.err != null) break;
       }
       std.debug.print("write error: {any}\n", .{writer.err});
   }
   ```

2. Run it with `zig run net_write_reset.zig`.

### Expected behaviour

`write error: error.ConnectionResetByPeer`.

### Actual behaviour

```
error.Unexpected NTSTATUS=0xc000013b (LOCAL_DISCONNECT)
lib\std\Io\Threaded.zig:13528:57: in netWriteWindows
        else => |status| return windows.unexpectedStatus(status),
lib\std\Io\Threaded.zig:2593:32: in operate
lib\std\Io\net.zig:1444:38: in drain
...
write error: error.Unexpected
```

### Impact

Any server that writes to clients which disconnect abruptly (closed browser tabs, killed
SSH clients) gets `error.Unexpected` and a stack trace instead of an error it can handle.

### Suggested fix

In `netWriteWindows`, map `.LOCAL_DISCONNECT` to `error.ConnectionResetByPeer`, next to
`.CONNECTION_RESET` and `.REMOTE_DISCONNECT` (line 13526). The same mapping is already
proposed for reads in #31956.

**Possibly related:** `netAcceptWindows` and `netShutdownWindows` send every status except
`INSUFFICIENT_RESOURCES` to `unexpectedStatus`. Once, in snek's tests, a
`CONNECTION_RESET` stack trace appeared from one of these paths. It could not be reproduced
on purpose, so it is only mentioned here.

---

## 4. `Stream.shutdown` does not wake a read blocked on the same socket on Windows

**Labels:** bug, lib/std, os-windows

### Description

One task is blocked reading a stream, and another task calls `shutdown(io, .both)` on that
stream. On Linux the blocked read returns end of stream at once. On Windows the read stays
blocked indefinitely.

### Steps to reproduce

1. Save as `net_read_shutdown.zig`:

   ```zig
   const std = @import("std");
   const net = std.Io.net;

   pub fn main(init: std.process.Init) !void {
       const io = init.io;
       const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
       var server = try loopback.listen(io, .{});
       defer server.deinit(io);
       const client = try server.socket.address.connect(io, .{ .mode = .stream });
       defer client.close(io);
       const conn = try server.accept(io);
       defer conn.close(io);

       // Block a read on `conn`, then shut `conn` down from this task.
       var reading = try io.concurrent(read, .{ io, conn });
       try io.sleep(.fromMilliseconds(200), .awake);
       try conn.shutdown(io, .both);
       std.debug.print("read error: {any}\n", .{reading.await(io)});
   }

   fn read(io: std.Io, stream: net.Stream) ?net.Stream.Reader.Error {
       var buffer: [64]u8 = undefined;
       var reader = stream.reader(io, &buffer);
       _ = reader.interface.takeByte() catch {};
       return reader.err;
   }
   ```

2. Run it with `zig run net_read_shutdown.zig`.

### Expected behaviour

`read error: null`, printed right after the 200 ms sleep, as on Linux.

### Actual behaviour

Nothing is printed. The program does not finish (killed after 20 s).

### Cause (likely)

`netShutdownWindows` issues `IOCTL_AFD_PARTIAL_DISCONNECT`. AFD does not complete a receive
that is already pending when the receive side is disconnected locally. Only new receives
fail (see issue 2).

### Impact

`shutdown` is the usual way to stop a reader task portably: a server shutting down, or a
connection handler giving up on an unresponsive peer. On Windows that task never ends, and
whoever awaits it hangs. snek's web server uses `shutdown` this way to stop a WebSocket
reader whose browser never answers the close frame, and on Windows that reader stays
blocked.

### Suggested fix

In `netShutdownWindows`, when the receive side is shut down, cancel receives pending on the
handle (`NtCancelIoFileEx`) and complete them as end of stream. Otherwise, document that on
Windows `shutdown` does not interrupt a pending read and callers must cancel it.

---

## 5. `Dir.setTimestamps` panics on Windows

**Labels:** bug, lib/std, os-windows

### Description

`Dir.setTimestamps` and `Dir.setTimestampsNow` hit `@panic("TODO implement dirSetTimestamps
windows")` (line 9307). `File.setTimestamps` works on Windows.

### Steps to reproduce

1. Save as `dir_set_timestamps.zig`:

   ```zig
   const std = @import("std");

   pub fn main(init: std.process.Init) !void {
       const io = init.io;
       const cwd = std.Io.Dir.cwd();
       try cwd.writeFile(io, .{ .sub_path = "stamped.txt", .data = "x" });
       defer cwd.deleteFile(io, "stamped.txt") catch {};
       try cwd.setTimestampsNow(io, "stamped.txt", .{});
       std.debug.print("ok\n", .{});
   }
   ```

2. Run it with `zig run dir_set_timestamps.zig`.

### Expected behaviour

`ok`.

### Actual behaviour

```
thread 6124 panic: TODO implement dirSetTimestamps windows
lib\std\Io\Threaded.zig:9307:9: in dirSetTimestamps
lib\std\Io\Dir.zig:2039:38: in setTimestampsNow
dir_set_timestamps.zig:9:29: in main
```

### Impact

Portable code (archive extraction, build tools, tests that age files) crashes on Windows,
and the panic cannot be caught. snek's tests open the file and use `File.setTimestamps`
instead.

### Suggested fix

Open `sub_path` relative to `dir` with `FILE_WRITE_ATTRIBUTES`, using
`FILE_OPEN_REPARSE_POINT` when `follow_symlinks` is false. Then reuse the
`fileSetTimestamps` Windows path and close the handle.
