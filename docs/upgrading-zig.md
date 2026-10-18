# Upgrading Zig

termancy builds with exactly one Zig release at a time, named in `build.zig.zon`
(`minimum_zig_version`) and in the README. Zig changes quickly, so each toolchain bump gets
a section here: what moved in the language and standard library, and what that means for
code built on termancy. Newest first.

## 0.16 → 0.17

**For code using termancy:** nothing in the `cli` or `cfg` API changed shape for the bump. Your
own code is likely to need the changes below.

### Build scripts

| 0.16 | 0.17 |
|---|---|
| `.optimize = .Debug`, `.ReleaseFast` | `.debug`, `.safe`, `.fast`, `.small`; the old names remain as aliases, and `-Doptimize=ReleaseSafe` still works |
| `b.pathFromRoot("src")` | a lazy path: `addFileArg(b.path("src"))` |
| `b.fmt("--dir={s}", .{path})` as one argument | `addArg("--dir")` then `addFileArg(...)`, or `addPrefixedFileArg("--dir=", ...)` |

### Language and standard library

- **`[_]T{v} ** n` is gone.** Use `@splat(v)` with a destination type:
  `const zeros: [16]u8 = @splat(0)`. Review each site rather than replacing blindly:
  `"─" ** 20` repeated a three-byte UTF-8 sequence (60 bytes), which `@splat` cannot
  express; write such strings out.
- **`@fromBackingInt` and `@backingInt`** convert between an enum (or packed type) and its
  integer. `zig fmt` rewrites `@enumFromInt(x)` to `@fromBackingInt(@intCast(x))`.
- **Type reflection uses parallel arrays.** `@typeInfo(T).@"struct".fields` became
  `field_names`, `field_types`, and `field_attrs`; `std.meta.fields(T)` with it. A field's
  default is `attrs.default_value_ptr`. Inside `inline for`, key `std.meta.fieldInfo` by
  the *index* (`@fromBackingInt(i)`), not the name, which is a runtime value.
  `Type.StructField` is gone: take the descriptor as `anytype`. `Enum.fields` became
  `field_names` and `field_values`; a function's `params[i].type` is `param_types[i]`.
- **`std.builtin` lives in `std/lang.zig`.** `std.builtin.OptimizeMode` still resolves.
- **`@min` and `@max` narrow their result type** to fit a comptime-known operand:
  `@min(len, 57)` is a `u6`. A counter initialized from one (`var filled = @min(...)`)
  overflows; give it a type (`var filled: usize = ...`).
- **I/O goes through `std.Io`.** Files and directories are `Io.File` and `Io.Dir`, every
  call takes the `io`; `main` receives a `std.process.Init` with `io`, `gpa`, the
  environment, and the arguments.
- **Compression:** `std.compress.flate.Compress.Raw` writes stored deflate (gzip or zlib
  framed); `Decompress.init(reader, .gzip, buffer)` reads.

### Tooling

- **Fuzzing and kcov need LLVM code.** The self-hosted x86 backend, the default for debug
  builds, emits no fuzzer instrumentation ("pcs_len was zero"), and kcov's breakpoints
  make some of its code misbehave. `zig build fuzz` and `zig build coverage` build their
  tests with `.use_llvm = true` for that reason.
- **Generic code that nothing calls is not analysed.** A green test suite after an upgrade
  does not prove every function compiles; termancy's tests instantiate each public generic
  writer for that reason.
- Keep the build cache on a native file system: under WSL, a cache on `/mnt/c` fails with
  `AccessDenied`. Pass `--cache-dir` to put it elsewhere.
