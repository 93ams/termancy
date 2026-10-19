//! Build graph: the `term`, `cli`, `cfg`, `tui`, and `sys` library modules, the `termancy`
//! executable, and the checks.
//!
//! | step                       | what it does                                                 |
//! |----------------------------|--------------------------------------------------------------|
//! | `zig build`                | builds and installs `termancy`                                   |
//! | `zig build run`            | runs `termancy` with the arguments after `--`                    |
//! | `zig build test`           | format check, unit, end-to-end, and compile-error tests      |
//! | `zig build unit`           | unit tests only                                              |
//! | `zig build e2e`            | end-to-end tests only: runs `termancy` over `test/fixtures`      |
//! | `zig build compile-errors` | checks that `cli` rejects bad commands at compile time       |
//! | `zig build check`          | compiles for Linux, macOS, Windows (WASI for cli/cfg, unit   |
//! |                            | tests for aarch64 Linux too)                                 |
//! | `zig build fmt`            | formats the sources in place                                 |
//! | `zig build bench`          | times `cfg` parsing, writing, merging, decoding (ReleaseFast) |
//! | `zig build budget`         | size and startup budgets of minimal `cli`/`cfg`/`tui` apps   |
//! | `zig build coverage`       | unit-test line coverage with kcov, to `zig-out/coverage`     |
//! | `zig build fuzz --fuzz`    | coverage-guided fuzzing of the parsers of untrusted input    |
//! | `zig build examples`       | builds, tests, and runs the apps in `examples/`              |
//! | `zig build docs`           | API and command reference, to `zig-out/docs`                 |
//! | `zig build site`           | the documentation site, to `zig-out/site` (`tools/site.zig`) |
//! | `zig build site-gifs`      | the site with each component's GIF, recorded from its tape   |
//! | `zig build console`        | `cli`'s Windows console code under a pseudo console          |

const std = @import("std");
const e2e = @import("test/e2e.zig");
const e2e_tui_widgets = @import("test/e2e_tui_widgets.zig");
const e2e_tui_registry = @import("test/e2e_tui_registry.zig");
const e2e_ssh = @import("test/e2e_ssh.zig");
const e2e_web = @import("test/e2e_web.zig");
const compile_errors = @import("test/compile_errors/cases.zig");

/// Compiled by `zig build check`, so platform-specific code is analysed for every target.
const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    // Released, and its calling convention differs from x86_64's.
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
};

const format_paths = [_][]const u8{ "build.zig", "src", "test", "bench", "examples", "tools" };

/// The apps in `examples/`, each run once by `zig build examples` (and `test`).
const Example = struct {
    name: []const u8,
    args: []const []const u8 = &.{},
    /// An argument that is a path in the repository, appended after `args`.
    path_arg: ?[]const u8 = null,
    /// Written before `path_arg`, in the same argument (`@` for a response file).
    path_prefix: []const u8 = "",
    path_is_dir: bool = false,
    env: []const [2][]const u8 = &.{},
    /// Standard input; none when null.
    stdin: ?[]const u8 = null,
    /// A new, empty directory, appended to this prefix as the last argument.
    empty_dir_prefix: ?[]const u8 = null,
    stdout: []const u8,
    /// Copies the registry's components into `ui/` beside `main.zig`, where `termancy tui add`
    /// puts them in a project made by `termancy cli init`.
    components: bool = false,
};

const examples = [_]Example{
    .{
        .name = "first-app",
        .args = &.{ "make", "--drink", "latte", "--cups", "2", "-q", "--config" },
        .path_arg = "examples/first-app/brew.toml",
        .components = true,
        .stdout = "2 latte, from 36g of Ethiopia Yirgacheffe\n",
    },
    .{
        .name = "deploy",
        .args = &.{
            "run",       "--service",   "api", "--env", "production", "--version", "1.4.0",
            "--migrate", "--no-canary", "-q",
        },
        .stdout = "api 1.4.0 is live on production\n",
    },
    .{
        .name = "httpc",
        .path_arg = "examples/httpc/request.args",
        .path_prefix = "@",
        .stdout =
        \\method:     POST
        \\url:        https://api.example.com/users
        \\query:      page=2
        \\headers:    X-Trace: 1, Accept: json, html
        \\body:       {"name":"ada","role":"admin"}
        \\timeout_ms: 5000
        \\max_bytes:  10485760
        \\tries:      2
        \\
        ,
    },
    .{
        .name = "settings",
        .args = &.{ "show", "--env", "production", "--file" },
        .path_arg = "examples/settings/app.toml",
        .env = &.{.{ "SETTINGS_PASSPHRASE", "example" }},
        .stdout =
        \\database.password = <redacted>  # file (secrets.toml.enc)
        \\database.pool = 20  # file (app.production.toml)
        \\database.url = postgres://db.prod/shop  # file (app.production.toml)
        \\log.format = text  # default
        \\log.level = info  # file (app.toml)
        \\schema_version = 3  # file (app.toml)
        \\server.host = 0.0.0.0  # file (app.toml)
        \\server.port = 443  # file (app.production.toml)
        \\server.timeout = 30s  # default
        \\
        ,
    },
    .{
        .name = "kv",
        .args = &.{"shell"},
        .empty_dir_prefix = "--store=",
        .stdin = "set greeting hello\nset name ada\nget greeting\nlist\n",
        .stdout = "hello\nKEY       VALUE\ngreeting  hello\nname      ada\n",
    },
    .{
        .name = "monitor",
        .args = &.{"--snapshot"},
        .stdout =
        \\◆ monitor  4 services
        \\
        \\Services │ Traffic │ Help
        \\
        \\╭─────────┬──────────┬──────────┬─────────╮  ╭────────────────────────────╮
        \\│ Service │ Status   │ Replicas │ Version │  │ api                        │
        \\├─────────┼──────────┼──────────┼─────────┤  │ version 1.4.0              │
        \\│ api     │ healthy  │        3 │ 1.4.0   │  │                            │
        \\│ web     │ healthy  │        2 │ 2.0.1   │  │ r to redeploy              │
        \\│ worker  │ degraded │        1 │ 0.9.3   │  ╰────────────────────────────╯
        \\│ billing │ healthy  │        2 │ 3.2.0   │
        \\╰─────────┴──────────┴──────────┴─────────╯
        \\
        \\↑/↓ service • r redeploy • q/esc quit • ←/→ tab
        \\
        ,
    },
    .{
        .name = "doctor",
        .args = &.{ "dirs", "--os", "windows" },
        .env = &.{
            .{ "USERPROFILE", "C:\\Users\\ada" },
            .{ "APPDATA", "C:\\Users\\ada\\AppData\\Roaming" },
            .{ "LOCALAPPDATA", "C:\\Users\\ada\\AppData\\Local" },
            .{ "TEMP", "C:\\Temp" },
        },
        .stdout =
        \\config   C:\Users\ada\AppData\Roaming\doctor
        \\cache    C:\Users\ada\AppData\Local\doctor\cache
        \\data     C:\Users\ada\AppData\Local\doctor\data
        \\state    C:\Users\ada\AppData\Local\doctor\state
        \\runtime  C:\Temp\doctor
        \\
        ,
    },
    .{
        .name = "git-style",
        .args = &.{ "log", "--format", "oneline", "-n", "2" },
        .stdout = "a1b2c3d Add the parser\ne4f5a6b Fix the writer\n",
    },
    .{
        .name = "server-config",
        .args = &.{ "--workers", "8", "--config" },
        .path_arg = "examples/server-config/server.toml",
        .env = &.{.{ "APP_PORT", "9000" }},
        .stdout =
        \\listening on 0.0.0.0:9000 with 8 workers, timeout 1m30s
        \\tls: on
        \\  host: file (server.toml)
        \\  port: env (APP_PORT)
        \\  workers: flag (--workers)
        \\  timeout: file (server.toml)
        \\
        ,
    },
    .{
        .name = "tasks",
        .args = &.{ "clear", "--dry-run", "--yes", "--config" },
        .path_arg = "examples/tasks/tasks.toml",
        .env = &.{.{ "LANG", "de_DE.UTF-8" }},
        .stdout = "Würde 2 Aufgaben löschen, älter als 7 Tage\n",
    },
    .{
        .name = "lobby",
        .args = &.{ "preview", "--user", "ada" },
        .stdout =
        \\╭─ lobby ──────────────────────────────────────────────────╮
        \\│ Welcome, ada. You have been here 0s.                     │
        \\│                                                          │
        \\│ grace: hello from the other side                         │
        \\╰──────────────────────────────────────────────────────────╯
        \\sign: a message, then enter
        \\enter signs • esc leaves
        \\
        ,
    },
    .{
        .name = "repos",
        .args = &.{ "list", "-o", "json", "-c" },
        .path_arg = "examples/repos/repos.toml",
        .empty_dir_prefix = "--roots=",
        .stdout = "[]\n",
    },
    .{
        .name = "conf-d",
        .path_arg = "examples/conf-d/conf.d",
        .path_is_dir = true,
        .stdout =
        \\3 files
        \\log.format = text  # 10-base.toml
        \\log.level = debug  # 20-site.yaml
        \\server.host = example.com  # 20-site.yaml
        \\server.port = 9090  # 30-local.json
        \\
        ,
    },
};

/// What `zig build console` runs: `test/console/app.zig` with `args`, under
/// `test/console/conpty.zig` with a console `columns` wide, taking `steps`.
const ConsoleCase = struct {
    args: []const []const u8,
    columns: []const u8 = "80",
    steps: []const []const u8,
};

const console_cases = [_]ConsoleCase{
    .{ .args = &.{"width"}, .columns = "73", .steps = &.{ "expect:width 73", "exit:0" } },
    .{
        .args = &.{"secret"},
        .steps = &.{
            "expect:Token",
            "send:hunter2\\r",
            "expect:got 7 bytes",
            "forbid:hunter2",
            "exit:0",
        },
    },
    .{
        .args = &.{"wait"},
        .steps = &.{ "expect:waiting", "send:\\x03", "expect:cleaned up", "exit:130" },
    },
    .{
        .args = &.{"ticks"},
        .steps = &.{ "expect:all five ticks", "send:q", "expect:quit after 5 ticks", "exit:0" },
    },
    .{
        .args = &.{"spin"},
        .steps = &.{ "expect:spinning", "send:\\x03", "expect:cursor shown", "exit:130" },
    },
    .{ .args = &.{"query"}, .steps = &.{ "expect:protocol ", "exit:0" } },
    .{
        .args = &.{"utf8"},
        .steps = &.{ "expect:value: çà ✓", "expect:code page 437 after", "exit:0" },
    },
};

/// The front page of `zig build docs`.
const docs_index =
    \\<!doctype html>
    \\<html lang="en">
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>termancy reference</title>
    \\<style>
    \\body { font: 16px/1.5 system-ui, sans-serif; max-width: 40em; margin: 2em auto;
    \\       padding: 0 1em }
    \\</style>
    \\<h1>termancy reference</h1>
    \\<h2>Libraries</h2>
    \\<ul>
    \\<li><a href="api/term/index.html">term</a>: the terminal: styles, width, escapes</li>
    \\<li><a href="api/cli/index.html">cli</a>: command-line applications</li>
    \\<li><a href="api/cfg/index.html">cfg</a>: layered configuration</li>
    \\<li><a href="api/tui/index.html">tui</a>: terminal user interfaces</li>
    \\<li><a href="api/sys/index.html">sys</a>: the operating system</li>
    \\</ul>
    \\<h2>The termancy program</h2>
    \\<ul>
    \\<li><a href="commands.html">Every command</a>,
    \\also as man pages in <code>man/man1</code></li>
    \\</ul>
    \\
;

/// The library modules, in the order `unit` runs them, each after the ones it imports.
const libraries = [_][]const u8{ "term", "field", "cli", "cfg", "tui", "sys" };

/// The libraries `name` imports besides `std`.
fn libraryImports(comptime name: []const u8) []const []const u8 {
    if (comptime std.mem.eql(u8, name, "cli")) return &.{ "term", "field" };
    if (comptime std.mem.eql(u8, name, "cfg")) return &.{"field"};
    if (comptime std.mem.eql(u8, name, "tui")) return &.{"term"};
    return &.{};
}

/// The index of `name` in `libraries`.
fn library(comptime name: []const u8) usize {
    inline for (libraries, 0..) |candidate, i| {
        if (comptime std.mem.eql(u8, candidate, name)) return i;
    }
    @compileError("no library " ++ name);
}

const Modules = struct {
    /// One per entry of `libraries`, in the same order.
    libs: [libraries.len]*std.Build.Module,
    termancy: *std.Build.Module,

    fn all(m: Modules) [libraries.len + 1]*std.Build.Module {
        return m.libs ++ [_]*std.Build.Module{m.termancy};
    }
};

/// The modules for one target. `exported` registers the libraries as modules other
/// packages can depend on; that is done once, for the host target.
fn modules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exported: bool,
    build_options: *std.Build.Module,
) Modules {
    var libs: [libraries.len]*std.Build.Module = undefined;
    var imports: [libraries.len]std.Build.Module.Import = undefined;
    inline for (libraries, &libs, &imports) |name, *lib, *import| {
        const options: std.Build.Module.CreateOptions = .{
            .root_source_file = b.path(b.fmt("src/{s}/root.zig", .{name})),
            .target = target,
            .optimize = optimize,
        };
        lib.* = if (exported) b.addModule(name, options) else b.createModule(options);
        inline for (comptime libraryImports(name)) |dependency| {
            lib.*.addImport(dependency, libs[library(dependency)]);
        }
        import.* = .{ .name = name, .module = lib.* };
    }
    const termancy = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = b.allocator.dupe(std.Build.Module.Import, &imports) catch @panic("OOM"),
    });
    termancy.addImport("build_options", build_options);
    return .{ .libs = libs, .termancy = termancy };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // What `termancy --version` reports beyond the version. Given, not detected, so that a build
    // is reproducible: a release passes `-Dcommit=$(git rev-parse HEAD) -Ddate=...`.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    options.addOption(?[]const u8, "commit", b.option([]const u8, "commit", "Git commit"));
    options.addOption(?[]const u8, "date", b.option([]const u8, "date", "Build date"));
    const build_options = options.createModule();
    const host = modules(b, target, optimize, true, build_options);

    const exe = b.addExecutable(.{ .name = "termancy", .root_module = host.termancy });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run termancy").dependOn(&run.step);

    const unit = b.step("unit", "Run the unit tests");
    // kcov runs each test binary and merges the reports; it needs Linux and kcov on PATH.
    const merge = b.addSystemCommand(&.{ "kcov", "--merge" });
    const merged = merge.addOutputDirectoryArg("coverage");
    for (host.all(), 0..) |module, i| {
        const tests = b.addTest(.{ .root_module = module });
        unit.dependOn(&b.addRunArtifact(tests).step);
        // kcov plants breakpoints from the line table, which needs LLVM's code: under the
        // self-hosted backend some tests misbehave once instrumented.
        const measured = b.addTest(.{ .root_module = module, .use_llvm = true });
        const kcov = b.addSystemCommand(&.{"kcov"});
        kcov.addPrefixedDirectoryArg("--include-path=", b.path("src"));
        merge.addDirectoryArg(kcov.addOutputDirectoryArg(b.fmt("unit-{d}", .{i})));
        kcov.addArtifactArg(measured);
    }
    const install_coverage = b.addInstallDirectory(.{
        .source_dir = merged,
        .install_dir = .prefix,
        .install_subdir = "coverage",
    });
    b.step("coverage", "Measure the unit tests' line coverage with kcov")
        .dependOn(&install_coverage.step);

    // The fuzzer's coverage instrumentation needs LLVM; without --fuzz this replays the
    // corpora like `unit` does. The fuzz tests are in each library's `fuzz.zig`, and the
    // tape parser's in its own test root, which `unit` runs too. ReleaseSafe: many more
    // runs a second than Debug, with the same safety checks.
    const fuzz = b.step("fuzz", "Fuzz the parsers of untrusted input (--fuzz, or --fuzz=100K)");
    const tape_test_root: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/cmd/record/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    };
    const tape_tests = b.addTest(.{ .root_module = b.createModule(tape_test_root) });
    unit.dependOn(&b.addRunArtifact(tape_tests).step);
    var tape_fuzz_root = tape_test_root;
    tape_fuzz_root.optimize = .ReleaseSafe;
    const safe = modules(b, target, .ReleaseSafe, false, build_options);
    for ([_]*std.Build.Module{
        safe.libs[library("term")],
        safe.libs[library("cfg")],
        safe.libs[library("sys")],
        b.createModule(tape_fuzz_root),
    }) |module| {
        const fuzz_tests = b.addTest(.{ .root_module = module, .use_llvm = true });
        fuzz.dependOn(&b.addRunArtifact(fuzz_tests).step);
    }

    // The Windows console code in `cli` (width, hidden prompts, Ctrl-C) run against a real
    // console host: natively on Windows, through WSL's interop on Linux.
    const windows = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows });
    const windows_libs = modules(b, windows, .debug, false, build_options).libs;
    const console_app = b.addExecutable(.{
        .name = "console",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/console/app.zig"),
            .target = windows,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "cli", .module = windows_libs[library("cli")] },
                .{ .name = "tui", .module = windows_libs[library("tui")] },
            },
        }),
    });
    const conpty = b.addExecutable(.{
        .name = "conpty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/console/conpty.zig"),
            .target = windows,
            .optimize = .debug,
        }),
    });
    const console = b.step("console", "Run cli's console code under a Windows pseudo console");
    for (console_cases) |case| {
        const check = b.addRunArtifact(conpty);
        check.setName(b.fmt("console {s}", .{case.args[0]}));
        check.addArg(case.columns);
        check.addArgs(case.steps);
        check.addArg("--");
        check.addArtifactArg(console_app);
        check.addArgs(case.args);
        // Under CI `cli` never prompts; these cases are about the console, so ask for it.
        check.setEnvironmentVariable("CI", "false");
        check.expectExitCode(0);
        console.dependOn(&check.step);
    }

    const examples_step = b.step("examples", "Build, test, and run the apps in examples/");
    // The registry's components, which a project would copy in with `termancy tui add`.
    const components = b.createModule(.{
        .root_source_file = b.path("src/cmd/tui/registry/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tui", .module = host.libs[library("tui")] }},
    });
    for (examples) |example| {
        const main_zig = b.path(b.fmt("examples/{s}/main.zig", .{example.name}));
        const root_source_file = if (example.components) assembled: {
            const project = b.addWriteFiles();
            _ = project.addCopyDirectory(b.path("src/cmd/tui/registry"), "ui", .{});
            break :assembled project.addCopyFile(main_zig, "main.zig");
        } else main_zig;
        const module = b.createModule(.{
            .root_source_file = root_source_file,
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "term", .module = host.libs[library("term")] },
                .{ .name = "field", .module = host.libs[library("field")] },
                .{ .name = "cli", .module = host.libs[library("cli")] },
                .{ .name = "cfg", .module = host.libs[library("cfg")] },
                .{ .name = "tui", .module = host.libs[library("tui")] },
                .{ .name = "sys", .module = host.libs[library("sys")] },
                .{ .name = "components", .module = components },
            },
        });
        const example_exe = b.addExecutable(.{ .name = example.name, .root_module = module });
        examples_step.dependOn(&b.addInstallArtifact(example_exe, .{}).step);
        // Tests read the example's files by their paths from the repository's root.
        const example_tests = b.addRunArtifact(b.addTest(.{ .root_module = module }));
        example_tests.setCwd(b.path("."));
        examples_step.dependOn(&example_tests.step);
        const run_example = b.addRunArtifact(example_exe);
        run_example.addArgs(example.args);
        if (example.path_arg) |path| {
            if (example.path_is_dir) {
                run_example.addPrefixedDirectoryArg(example.path_prefix, b.path(path));
            } else {
                run_example.addPrefixedFileArg(example.path_prefix, b.path(path));
            }
        }
        for (example.env) |pair| run_example.setEnvironmentVariable(pair[0], pair[1]);
        if (example.stdin) |bytes| run_example.setStdIn(.{ .bytes = bytes });
        if (example.empty_dir_prefix) |prefix| {
            _ = run_example.addPrefixedOutputDirectoryArg(prefix, "empty");
        }
        run_example.expectStdOutEqual(example.stdout);
        examples_step.dependOn(&run_example.step);
    }

    const docs = b.step("docs", "Generate the API and command reference into zig-out/docs");
    var api: [libraries.len]std.Build.LazyPath = undefined;
    for (host.libs, libraries, &api) |module, name, *emitted| {
        const object = b.addObject(.{ .name = name, .root_module = module });
        emitted.* = object.getEmittedDocs();
        docs.dependOn(&b.addInstallDirectory(.{
            .source_dir = emitted.*,
            .install_dir = .prefix,
            .install_subdir = b.fmt("docs/api/{s}", .{name}),
        }).step);
    }
    const html = b.addRunArtifact(exe);
    html.addArgs(&.{ "cli", "docs", "--format", "html" });
    docs.dependOn(&b.addInstallFile(html.captureStdOut(.{}), "docs/commands.html").step);
    const man = b.addRunArtifact(exe);
    man.addArgs(&.{ "cli", "docs", "--format", "man", "--dir" });
    docs.dependOn(&b.addInstallDirectory(.{
        .source_dir = man.addOutputDirectoryArg("man1"),
        .install_dir = .prefix,
        .install_subdir = "docs/man/man1",
    }).step);
    const index = b.addWriteFiles().add("index.html", docs_index);
    docs.dependOn(&b.addInstallFile(index, "docs/index.html").step);

    const site_tool = b.addExecutable(.{ .name = "site", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/site.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    unit.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = site_tool.root_module })).step);
    addSite(b, b.step("site", "Generate the documentation site into zig-out/site"), .{
        .termancy = exe,
        .tool = site_tool,
        .api = api,
    });
    addSite(b, b.step("site-gifs", "Record the components' GIFs, then generate the site"), .{
        .termancy = exe,
        .tool = site_tool,
        .api = api,
        .gifs = true,
    });

    const end_to_end = b.step("e2e", "Run the end-to-end tests");
    e2e.addCases(b, exe, end_to_end);
    e2e_tui_widgets.addCases(b, exe, end_to_end);
    e2e_tui_registry.addCases(b, exe, end_to_end);
    e2e_ssh.addCases(b, exe, host.libs[library("sys")], end_to_end);
    e2e_web.addCases(b, exe, host.libs[library("sys")], end_to_end);

    const rejected = b.step("compile-errors", "Check that cli rejects bad commands when compiling");
    compile_errors.addCases(b, rejected);

    const format_check = b.addFmt(.{ .paths = lazyPaths(b, &format_paths), .check = true });
    const test_step = b.step("test", "Check formatting, then run every test");
    test_step.dependOn(&format_check.step);
    test_step.dependOn(unit);
    test_step.dependOn(end_to_end);
    test_step.dependOn(rejected);
    test_step.dependOn(examples_step);

    // Timings are only meaningful optimized, whatever `-Doptimize` says.
    const fast = modules(b, target, .ReleaseFast, false, build_options);
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "cfg", .module = fast.libs[library("cfg")] }},
    }) });
    b.step("bench", "Time cfg's parsers, writers, merge, and decode")
        .dependOn(&b.addRunArtifact(bench_exe).step);

    // The smallest application on each of `cli`, `cfg`, and `tui`, as an application ships.
    const small = modules(b, target, .ReleaseSmall, false, build_options);
    const budget_exe = b.addExecutable(.{ .name = "budget", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/budget.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }) });
    const budget_run = b.addRunArtifact(budget_exe);
    inline for (.{ "cli", "cfg", "tui" }) |name| {
        const app = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
            .root_source_file = b.path("bench/budget/" ++ name ++ ".zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .strip = true,
            .imports = &.{.{ .name = name, .module = small.libs[library(name)] }},
        }) });
        budget_run.addPrefixedArtifactArg(name ++ "=", app);
    }
    budget_run.has_side_effects = true;
    b.step("budget", "Check the size and startup time of the smallest applications")
        .dependOn(&budget_run.step);

    const format = b.addFmt(.{ .paths = lazyPaths(b, &format_paths) });
    b.step("fmt", "Format the sources").dependOn(&format.step);

    const check = b.step("check", "Compile everything for every supported target");
    for (check_targets) |query| {
        const cross = modules(b, b.resolveTargetQuery(query), optimize, false, build_options);
        check.dependOn(&b.addExecutable(.{ .name = "termancy", .root_module = cross.termancy }).step);
        for (cross.all()) |module| {
            check.dependOn(&b.addTest(.{ .root_module = module }).step);
        }
    }
    // The unit tests, compiled (not run) for a second architecture whose page size is known
    // only at run time, so code that assumes a comptime page size cannot creep back in.
    const arm = modules(b, b.resolveTargetQuery(arm_target), optimize, false, build_options);
    for (arm.all()) |module| check.dependOn(&b.addTest(.{ .root_module = module }).step);
    // `cli` and `cfg` (and `term` under them) also run inside WASM hosts (`App.executeLine`);
    // `tui` and `sys` need a real operating system and are not built for WASI.
    const wasi = modules(b, b.resolveTargetQuery(wasi_target), optimize, false, build_options);
    for (wasi.libs, libraries) |module, name| {
        if (!isWasiLibrary(name)) continue;
        check.dependOn(&b.addTest(.{ .root_module = module }).step);
    }
}

const Site = struct {
    termancy: *std.Build.Step.Compile,
    tool: *std.Build.Step.Compile,
    /// Each library's API reference, as `zig build docs` makes it.
    api: [libraries.len]std.Build.LazyPath,
    /// Record `docs/tapes/<component>.tape` with `termancy record`. Each GIF is cached until
    /// termancy or the tape changes; without them, the gallery says how to record them.
    gifs: bool = false,
};

/// `step` writes `zig-out/site` with `tools/site.zig`, from what termancy itself prints.
fn addSite(b: *std.Build, step: *std.Build.Step, site: Site) void {
    const commands = b.addRunArtifact(site.termancy);
    commands.addArgs(&.{ "cli", "docs", "--format", "html", "--stylesheet", "style.css" });
    const listing = b.addRunArtifact(site.termancy);
    listing.addArgs(&.{ "tui", "list", "-o", "json", "-C" });
    _ = listing.addOutputDirectoryArg("project");

    const generate = b.addRunArtifact(site.tool);
    // It reads directories, which the cache would not hash; it takes a moment anyway.
    generate.has_side_effects = true;
    const out = generate.addOutputDirectoryArg("site");
    generate.addDirectoryArg(b.path("src"));
    generate.addDirectoryArg(b.path("src/cmd/tui/registry"));
    generate.addFileArg(listing.captureStdOut(.{}));
    generate.addFileArg(commands.captureStdOut(.{}));
    generate.addFileArg(b.path("docs/guide.md"));
    if (site.gifs) for (tapes(b)) |name| {
        // The tapes type `termancy ...`, so the termancy being built goes first on PATH.
        const record = b.addSystemCommand(&.{
            "sh",
            "-c",
            "PATH=\"$(dirname \"$1\"):$PATH\" exec \"$1\" record -q \"$2\" -o \"$3\"",
            "record",
        });
        record.setName(b.fmt("record {s}", .{name}));
        record.addArtifactArg(site.termancy);
        record.addFileArg(b.path(b.fmt("docs/tapes/{s}.tape", .{name})));
        const gif = record.addOutputFileArg(b.fmt("{s}.gif", .{name}));
        generate.addPrefixedFileArg(b.fmt("{s}=", .{name}), gif);
    };
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = out,
        .install_dir = .prefix,
        .install_subdir = "site",
    }).step);
    for (site.api, libraries) |emitted, name| {
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = emitted,
            .install_dir = .prefix,
            .install_subdir = b.fmt("site/api/{s}", .{name}),
        }).step);
    }
}

/// The names of the tapes in `docs/tapes`, sorted.
fn tapes(b: *std.Build) []const []const u8 {
    const io = b.graph.io;
    b.dependOnDirectoryMetadata(b.path("docs/tapes"));
    var dir = b.root.openDir(io, "docs/tapes", .{ .iterate = true }) catch |err| {
        std.debug.panic("docs/tapes: {t}", .{err});
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("docs/tapes: {t}", .{err})) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".tape")) continue;
        names.append(b.allocator, b.dupe(entry.name[0 .. entry.name.len - 5])) catch
            @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    return names.items;
}

const wasi_target: std.Target.Query = .{ .cpu_arch = .wasm32, .os_tag = .wasi };
const arm_target: std.Target.Query = .{ .cpu_arch = .aarch64, .os_tag = .linux };

fn isWasiLibrary(name: []const u8) bool {
    return std.mem.eql(u8, name, "term") or std.mem.eql(u8, name, "field") or
        std.mem.eql(u8, name, "cli") or std.mem.eql(u8, name, "cfg");
}

fn lazyPaths(b: *std.Build, paths: []const []const u8) []const std.Build.LazyPath {
    const out = b.allocator.alloc(std.Build.LazyPath, paths.len) catch @panic("OOM");
    for (paths, out) |p, *lazy| lazy.* = b.path(p);
    return out;
}
