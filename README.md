# termancy

Six Zig libraries for command-line and terminal programs, and a program built from them.
Zig **0.17.0**, standard library only.

| | | |
|---|---|---|
| [**`cli`**](docs/cli.md) | command trees, flags decoded into structs, help, completion, generated docs | like [cobra] |
| [**`cfg`**](docs/cfg.md) | layered configuration in TOML, YAML, JSON, ZON, dotenv, INI, decoded into structs | like [viper] |
| [**`field`**](docs/field.md) | what settings mean, shared by `cli` and `cfg`: help, secrets, checks, by type | |
| [**`term`**](docs/term.md) | styles, layout, Unicode widths, a terminal emulator, Markdown, images in the terminal | like lipgloss, x/vt, glamour |
| [**`tui`**](docs/tui.md) | Elm-architecture UIs, components you copy and own, headless tests, serving over SSH | like Bubble Tea, Bubbles, huh |
| [**`sys`**](docs/sys.md) | directories, processes, secure memory, logging, self-update, an SSH server | like wish, log, melt |
| [**`termancy`**](docs/termancy.md) | the program: config tooling, generators, gum-style widgets, glow, vhs, freeze | |

`cli` and `tui` build on `term`, and `cli` and `cfg` on `field`; otherwise no library imports
another, so `cli` and `cfg` work alone or together.

[cobra]: https://github.com/spf13/cobra
[viper]: https://github.com/spf13/viper

## Install

### The program

Each [release](https://github.com/93ams/termancy/releases) has an archive per system
(`termancy-<os>-<cpu>.tar.gz`, `.zip` on Windows; `linux`, `macos`, `windows` on `x86_64` and
`aarch64`), each with an Ed25519 signature beside it and all in `SHA256SUMS`.

```sh
curl -fsSL https://github.com/93ams/termancy/releases/latest/download/termancy-linux-x86_64.tar.gz \
  | tar -xz -C ~/.local/bin termancy
scoop install https://github.com/93ams/termancy/releases/latest/download/termancy.json  # Windows
termancy update  # later: checks the signature, then swaps
```

The release also carries Homebrew (`termancy.rb`) and winget (`termancy.yaml`; `winget install
--manifest termancy.yaml`) manifests. To build it instead: `zig build -Doptimize=ReleaseSafe`
with Zig 0.17.0.

On Windows, `termancy.exe` is not code-signed yet, so the first run of a downloaded copy may
stop at a SmartScreen warning ("Windows protected your PC"): check it against `SHA256SUMS`,
then choose **More info**, **Run anyway**.

### The libraries

```sh
zig fetch --save git+https://github.com/93ams/termancy#v0.1.0
```

then import the modules you use in `build.zig`:

```zig
const termancy = b.dependency("termancy", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("cli", termancy.module("cli"));
exe.root_module.addImport("cfg", termancy.module("cfg"));
exe.root_module.addImport("field", termancy.module("field"));
exe.root_module.addImport("tui", termancy.module("tui"));
exe.root_module.addImport("sys", termancy.module("sys"));
```

Or let `termancy` set the project up ([below](#start-a-project)).

## A complete example

```zig
const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const field = @import("field");

const Settings = struct {
    host: []const u8 = "localhost",
    port: u16 = 8080,
    timeout: cfg.Duration = .{ .ns = 30 * std.time.ns_per_s },
};

const ServeFlags = struct {
    config: ?[]const u8 = null,
    settings: Settings = .{}, // every setting is a flag too: --host, --port, --timeout
};

// What the values mean, for the file, the environment, and the flags alike.
const Specs = field.Set(.{
    field.Spec(Settings){ .fields = .{
        .port = .{ .help = "Port to listen on", .checks = &.{.min(1)} },
    } },
    field.Spec(ServeFlags){ .fields = .{ .config = .{ .help = "Config file" } } },
});

const settings = cfg.settings(Settings, Specs, .{});

// How they are spelled on the command line.
const serve_flags = cli.flags(ServeFlags, Specs, .{ .fields = .{
    .config = .{ .short = 'c' },
    .settings = .{ .name = "", .fields = .{ .port = .{ .short = 'p' } } },
} });

// Defaults, then the file, then APP_* variables, then the flags.
fn load(ctx: *cli.Context) !Settings {
    const flags = try ctx.flags(ServeFlags);
    var config: cfg.Config = try .initFor(settings, ctx.arena);
    if (flags.config) |file| try config.loadFile(ctx.io, .cwd(), file, null, null);
    config.useEnv(ctx.environ);
    try config.automaticEnv("APP"); // APP_PORT=9000
    try config.bindFlags(try ctx.changedFlags(), .{}); // --port 9001
    var diag: cfg.Diagnostic = .{};
    return config.decode(settings, .{}, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => ctx.configError("{f}", .{diag}),
    };
}

fn serve(ctx: *cli.Context, flags: ServeFlags) !void {
    const s = flags.settings;
    try ctx.out.print("listening on {s}:{d}\n", .{ s.host, s.port });
}

const root = cli.command(.{
    .name = "app",
    .summary = "An example",
    .subcommands = .{
        cli.command(.{
            .name = "serve",
            .summary = "Serve",
            .flags = serve_flags,
            .settings = .{ .field = .settings, .load = load },
            .run = serve,
        }),
    },
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root, .version = "0.1.0" };
    return app.run(init);
}
```

`app serve --port 9001` prints `listening on localhost:9001`; so does `APP_PORT=9001 app
serve`, or a `port = 9001` line in the file given with `-c`.

## Start a project

```sh
termancy cli init demo --module-path /path/to/termancy   # or --fetch <url> to add it with zig fetch
cd demo
termancy cli add serve --flag 'port:u16=8080,short=p' --summary "Start serving"
termancy cli add config get --flag 'key:string,required'
zig build run -- serve -p 9000
```

- `init` writes `build.zig`, `build.zig.zon`, `src/main.zig` (the entry point and the command
  tree), an example `hello` command in `src/cmd/hello.zig`, and `src/settings.zig`, whose
  `Settings` struct is what the configuration file holds.
- `zig build schema` writes that struct's JSON Schema, from which `termancy cfg init demo.toml
  --schema zig-out/schema.json` writes a starter file.
- `add` writes one file per command with a typed flags struct, a handler, and a test, and wires
  it into its parent. A path like `config get` creates the `config` group
  (`src/cmd/config/main.zig`) when it is missing.

The generated project builds and its tests pass with no edits. For a walkthrough, read
[Your first app in 10 minutes](docs/guide.md).

## Documentation

| | |
|---|---|
| [Your first app in 10 minutes](docs/guide.md) | a guided tour: config, a flow, live progress, a TUI picker |
| [`cli`](docs/cli.md), [`cfg`](docs/cfg.md), [`field`](docs/field.md), [`term`](docs/term.md), [`tui`](docs/tui.md), [`sys`](docs/sys.md) | each library in depth |
| [The `termancy` program](docs/termancy.md) | every command |
| [Examples](examples/README.md) | small runnable apps, each showing a set of features |
| [Coming from Charm](docs/coming-from-charm.md) | where each Charm library and tool's work is done here |
| [Machine output](docs/machine-output.md) | what `termancy` prints for scripts, as a contract |
| [Stability](docs/stability.md) | the versioning policy and what is public |
| [Windows](docs/windows.md) | the state of Windows support |
| [Development](docs/development.md) | layout, build steps, testing, design notes |

`zig build docs` writes the API reference, and `zig build site` the documentation site.

## Project

- [ROADMAP.md](ROADMAP.md): what comes next, and what is left out on purpose.
- [CHANGELOG.md](CHANGELOG.md): what changed.
- [CONTRIBUTING.md](CONTRIBUTING.md): how to help.
- [SECURITY.md](SECURITY.md): how to report a vulnerability.
