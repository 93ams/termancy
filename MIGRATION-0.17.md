## Zig 0.17 migration — complete

The repository moved from **0.16.0** to **0.17.0**. Every gate is green and the test total is
**unchanged at 601/602** (1 skipped), which is the evidence that no test was lost or newly
collected by the migration.

Order of work followed the guide: `build.zig` errors first (Zig configures dependency build
scripts before compiling your source), then source errors.

### `build.zig`

| 0.16 | 0.17 |
|---|---|
| `b.pathFromRoot("src")` | `addFileArg(b.path("src"))` |
| `.optimize = .Debug` | `.optimize = .debug` |
| `if (optimize != .Debug)` | `if (optimize != .debug)` |
| `b.fmt("--modules={s}", .{path})` | `addArg("--modules")` then `addFileArg(...)` |

`Optimize` variants are lowercase in 0.17. `b.pathFromRoot` is gone; lazy paths are the
replacement, and `addFileArg` keeps the dependency visible to the build graph.

`import_lint.zig` takes `--modules` as a separate token rather than `--modules=<dir>` because
`addFileArg` appends one argument and cannot interpolate a path into a formatted string.

### Source

**93 `std.meta.fields(T)` call sites across 13 files.** The replacement is
`@typeInfo(T).@"struct".field_names`, which keeps the same `[]const u8` shape, so most bodies
needed no change. A parenthesised walk did the rewrite: a regex cannot, because 78 of the 93
calls contain a nested paren or comma.

**60 `inline for` loops over that expression.** The migration had to give each one an index and
look the descriptor up:

```zig
const fnames0 = @typeInfo(ConfigT).@"struct".field_names;
inline for (fnames0, 0..) |_, i| {
    const field = std.meta.fieldInfo(ConfigT, @enumFromInt(i));
    // field.name / field.type / field.attrs, as before
}
```

Three things about that shape cost time, and all three are worth knowing:

* **The key must be the *index*, not the name.** `field_names[i]` is a runtime slice element, so
  `fieldInfo(T, field_names[i])` fails with *"unable to resolve comptime value"*. The index
  inside an `inline for` is comptime, so it works — and `@enumFromInt` is needed because
  `fieldInfo` takes the generated `FieldEnum`, not a `usize`.
* **`Struct.fields` became three parallel arrays:** `field_names`, `field_types`, `field_attrs`.
  Code that wanted "the last field's type" now uses `field_types`, and code that counted fields
  uses `field_names.len`.
* **`Type.StructField` no longer exists,** so parameters typed with it cannot be fixed by
  changing a path — they take the descriptor as `anytype`.

Other 0.17 changes:

* **`[x]T{v} ** n` is gone.** 31 sites became `@splat(v)` with an explicit destination type. The
  guide's warning to review rather than replace blindly was correct: three box-drawing sites
  were `"<U+2500>" ** 20`, which repeated the **three-byte UTF-8 sequence**, giving **60 bytes**,
  not 20. `@splat` cannot express that — a codepoint does not fit a `u8` — so those are written
  as byte arrays.
* **`field.default_value_ptr` moved to `field.attrs.default_value_ptr`** (19 sites).
* **`fn_info.params[i].type` became `param_types[i]`**, a `?type`, so the optional is the element.
* **`Enum.fields` became `field_names`/`field_values`**, and `ErrorSet` exposes
  `error_names: ?[]const [:0]const u8`.
* **`MergeFlags`** was rebuilt for the parallel-array shape; `@Struct` itself is unchanged.
* **`@setEvalBranchQuota(20_000)`** was needed in `parseFlags`: `fieldInfo` over a merged flags
  type exceeds the default 1000 backwards branches.

### What the migration cost, and why

The bulk rewrites were the risky part, and this session proved it twice more:

* Two scripts wrote **CRLF** into source files, which made `zig fmt` fail on unrelated lines
  further up the file — 0.16 and 0.17 both read a trailing CR as whitespace inside an
  expression. Normalise line endings before and after any scripted write.
* One PowerShell replacement used a **double-quoted** string containing `""`, which collapsed to
  an empty string and corrupted a file. Patterns containing quotes must be single-quoted.
* A `.Replace('zfield_name)', ...)` matched **inside** `fieldInfo(...zfield_name)` and corrupted
  the identifier (`field` → `ield`, `other` → `ther`). Substring replacement on generated
  identifiers needs word boundaries, or the names must be chosen so they cannot collide.

Also: the build failed for a while with `FileSystemFailure` / `OutOfMemory` in unrelated std
files. That was **disk pressure** — 3.96 GB free with a 2.7 GB `.zig-cache` — not a code fault.
Dropping the cache and stale temp trees restored it.
