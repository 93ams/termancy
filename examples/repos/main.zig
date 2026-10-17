//! A dashboard for the git repositories on this machine: it finds them under the roots in
//! its configuration, says which are dirty, ahead, or behind, fetches them all at once,
//! and browses them in a terminal (or a browser) interface. It shows:
//!
//! - `cfg`: a TOML file in the user's configuration directory, `REPOS_*` variables over it
//!   (`REPOS_ROOTS=~/work,~/oss`, `REPOS_FETCH_CONCURRENCY=8`), flags over both;
//! - `cli.Flow`: a first-run setup that asks for the roots, offers the usual places
//!   (`~/src`, `~/code`, `~/projects`) only when some exist, counts what it found, and
//!   writes the file, keeping its comments when it already exists (`cfg.edit`);
//! - `ctx.render`: `list -o text|json|jsonl|yaml` from one struct;
//! - `ctx.live`: `fetch` runs `git fetch` on several repositories at once, with a step
//!   per repository and a bar for all of them;
//! - `tui`: `ui` is a table to filter as you type (`/`) beside a scrolling details pane,
//!   from the `table`, `input`, `filter`, and `viewport` components that
//!   `snek tui add table filter viewport` copied into `ui/` (see `tui.zon`);
//! - `platform.web`: `ui --web 127.0.0.1:7681` serves the same interface to browsers.
//!
//!     zig build examples
//!     zig-out/bin/repos setup                      # asks, at a terminal
//!     zig-out/bin/repos list
//!     zig-out/bin/repos list -o jsonl --roots ~/src | jq -r 'select(.dirty > 0) | .name'
//!     zig-out/bin/repos fetch
//!     zig-out/bin/repos ui
//!     zig-out/bin/repos ui --web 127.0.0.1:7681    # then open the link it prints

const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const term = @import("term");
const tui = @import("tui");
const platform = @import("platform");
const Table = @import("ui/table.zig").Table;
const Input = @import("ui/input.zig").Input;
const Viewport = @import("ui/viewport.zig").Viewport;
const fuzzy = @import("ui/filter.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const web = platform.web;

// Configuration.

pub const Settings = struct {
    /// Directories searched for repositories; `~` is the home directory.
    roots: []const []const u8 = &.{},
    /// Directory names not searched, `*` matching any run of characters.
    ignore: []const []const u8 = &.{ "node_modules", "vendor", "target", ".*" },
    /// How many directories below a root a repository may be.
    depth: u8 = 3,
    fetch: Fetch = .{},

    pub const Fetch = struct {
        /// Repositories fetched at once.
        concurrency: u8 = 4,
        /// How long one `git fetch` may take.
        timeout: cfg.Duration = .{ .ns = 120 * std.time.ns_per_s },
        pub const meta = .{ .concurrency = .{ .min = 1, .max = 64 } };
    };

    pub const meta = .{ .depth = .{ .min = 1, .max = 16 } };
};

/// On every command.
const Global = struct {
    config: ?[]const u8 = null,
    pub const meta = .{ .config = .{
        .short = 'c',
        .env = "REPOS_CONFIG",
        .value_name = "file",
        .help = "The configuration file (default: config.toml in the user's configuration " ++
            "directory for repos)",
    } };
};

/// The roots, on the commands that search.
const Search = struct {
    roots: []const []const u8 = &.{},
    pub const meta = .{ .roots = .{
        .split = ',',
        .value_name = "dir",
        .help = "Search these directories instead of the configured roots",
    } };
};

const Loaded = struct {
    /// Where the file is, or would be.
    path: []const u8,
    /// The file exists.
    found: bool,
    settings: Settings,
};

/// Defaults, then the file, then `REPOS_*`, then the flags that name settings (`--roots`,
/// `-j`). The `Config` is in the invocation's arena, so the settings live as long.
fn load(ctx: *cli.Context) !Loaded {
    const global = try ctx.flags(Global);
    var config: cfg.Config = .init(ctx.arena);
    try config.setDefaults(Settings{});
    config.useEnv(ctx.environ);
    var diag: cfg.Diagnostic = .{};
    const file = config.loadAppFile(ctx.io, "repos", .{ .path = global.config }, &diag) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => return ctx.fail("{f}", .{diag}),
            error.NoConfigDir => return ctx.fail("no configuration directory; pass --config", .{}),
            else => return ctx.fail("{s}: {t}", .{ global.config orelse "configuration", err }),
        };
    try config.automaticEnv("REPOS");
    try config.bindFlags(try ctx.changedFlags(), .{});
    const settings = config.decode(Settings, .{}, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail("{f}", .{diag}),
    };
    return .{ .path = file.path, .found = file.found, .settings = settings };
}

/// The settings, with at least one root: on the first run at a terminal, after the setup.
fn settingsWithRoots(ctx: *cli.Context) !Settings {
    const loaded = try load(ctx);
    if (loaded.settings.roots.len > 0) return loaded.settings;
    if (loaded.found or !ctx.interactive) {
        return ctx.fail("no roots to search: run repos setup, set REPOS_ROOTS, or pass " ++
            "--roots", .{});
    }
    try ctx.err.print("{s} does not exist yet; let's write it.\n", .{loaded.path});
    var state: Setup = .{ .file = loaded.path };
    _ = try setup.run(ctx, &state);
    return (try load(ctx)).settings;
}

// Setup: a flow.

/// The setup's state, and the flags of `repos setup`.
const Setup = struct {
    roots: []const []const u8 = &.{},
    usual: bool = true,
    concurrency: u8 = 4,
    /// The usual places that exist and are not roots yet, found by `lookAround`.
    extra: []const []const u8 = &.{},
    /// Repositories under the chosen roots, counted by `count`.
    found: usize = 0,
    /// The configuration file to write.
    file: []const u8 = "",

    pub const meta = .{
        .roots = .{ .split = ',', .help = "Directories to search", .value_name = "dirs" },
        .usual = .{ .help = "Also search ~/src, ~/code, and ~/projects, those that exist" },
        .concurrency = .{
            .help = "Repositories to fetch at once",
            .min = 1,
            .max = 64,
            .key = "fetch.concurrency",
        },
        .extra = .{ .internal = true },
        .found = .{ .internal = true },
        .file = .{ .internal = true },
    };

    /// The roots, with the usual places when they were chosen.
    fn rootList(state: *const Setup, arena: Allocator) ![]const []const u8 {
        if (!state.usual) return state.roots;
        return std.mem.concat(arena, []const u8, &.{ state.roots, state.extra });
    }
};

const SetupStep = enum { roots, look, ask_usual, count, ask_concurrency, save };

const usual_places = [_][]const u8{ "~/src", "~/code", "~/projects" };

const setup: cli.Flow(Setup, SetupStep) = .{ .start = .roots, .steps = .{
    .roots = .{
        .ask = .{ .field = "roots", .label = "Where are your repositories? (directories, " ++
            "separated by commas)" },
        .next = .look,
    },
    .look = .{ .title = "Look for the usual places", .run = lookAround, .probe = true, .decide = .{
        .to = &.{ .ask_usual, .count },
        .by = afterLook,
    } },
    .ask_usual = .{
        .ask = .{ .field = "usual", .label = "Also search the usual places?", .label_fn = usual },
        .next = .count,
    },
    .count = .{
        .title = "Count the repositories",
        .run = count,
        .probe = true,
        .next = .ask_concurrency,
    },
    .ask_concurrency = .{
        .ask = .{ .field = "concurrency", .label = "How many repositories to fetch at once?" },
        .next = .save,
    },
    .save = .{ .title = "Write the configuration", .run = save },
} };

fn lookAround(ctx: *cli.Context, state: *Setup) !void {
    var extra: std.ArrayList([]const u8) = .empty;
    defer state.extra = extra.items;
    if (home(ctx) == null) return;
    for (usual_places) |place| {
        const path = try expandHome(ctx, place);
        Io.Dir.cwd().access(ctx.io, path, .{}) catch continue;
        for (state.roots) |dir| {
            if (std.mem.eql(u8, try expandHome(ctx, dir), path)) break;
        } else try extra.append(ctx.arena, place);
    }
    ctx.log(.info, "{d} usual places exist and are not roots yet", .{extra.items.len});
}

fn afterLook(state: *const Setup) ?SetupStep {
    return if (state.extra.len > 0) .ask_usual else .count;
}

/// The question names the places found: "Also search ~/src and ~/code?".
fn usual(ctx: *cli.Context, state: *const Setup) ![]const u8 {
    const extra = state.extra;
    const last = extra[extra.len - 1];
    if (extra.len == 1) return std.fmt.allocPrint(ctx.arena, "Also search {s}?", .{last});
    const rest = try std.mem.join(ctx.arena, ", ", extra[0 .. extra.len - 1]);
    return std.fmt.allocPrint(ctx.arena, "Also search {s} and {s}?", .{ rest, last });
}

fn count(ctx: *cli.Context, state: *Setup) !void {
    const roots = try state.rootList(ctx.arena);
    if (roots.len == 0) return ctx.fail("no directories to search; pass --roots", .{});
    const found = try discover(ctx, .{ .roots = roots });
    state.found = found.len;
    if (ctx.output == .text) try ctx.err.print("  {d} repositories under {s}\n", .{
        found.len, try std.mem.join(ctx.arena, ", ", roots),
    });
}

/// Writes the roots and the concurrency into the file, changing only those keys when it
/// exists, so its comments and other settings stay.
fn save(ctx: *cli.Context, state: *Setup) !void {
    const path = state.file;
    const format = cfg.Format.fromPath(path) orelse
        return ctx.fail("{s}: not a configuration format (.toml, .yaml, .json, ...)", .{path});
    const cwd = Io.Dir.cwd();
    const before = cwd.readFileAlloc(ctx.io, path, ctx.arena, .limited(1 << 20)) catch |err|
        switch (err) {
            error.FileNotFound => "",
            error.OutOfMemory => return error.OutOfMemory,
            else => return ctx.fail("{s}: {t}", .{ path, err }),
        };
    const roots = try cfg.encode(ctx.arena, try state.rootList(ctx.arena));
    const changes = [_]cfg.edit.Change{
        .{ .set = .{ .key = "roots", .value = roots } },
        .{ .set = .{ .key = "fetch.concurrency", .value = .{ .int = state.concurrency } } },
    };
    const text = try cfg.edit.applyAll(ctx.arena, format, before, &changes) orelse
        return ctx.fail("{s}: cannot change it in place; edit the file by hand", .{path});
    platform.files.writeAtomic(ctx.io, cwd, path, text, .{ .make_path = true }) catch |err|
        return ctx.fail("{s}: {t}", .{ path, err });
    if (ctx.output == .text) try ctx.out.print("wrote {s}\n", .{path});
}

fn runSetup(ctx: *cli.Context, flags: Setup) !void {
    // The questions offer what the flags and the configuration say now.
    const now = try load(ctx);
    var state = flags;
    state.roots = now.settings.roots;
    state.concurrency = now.settings.fetch.concurrency;
    state.file = now.path;
    _ = try setup.run(ctx, &state);
}

fn home(ctx: *cli.Context) ?[]const u8 {
    return ctx.environ.get("HOME") orelse ctx.environ.get("USERPROFILE");
}

/// `~` and `~/...` from `$HOME`; anything else as it is.
fn expandHome(ctx: *cli.Context, path: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, path, "~") and !std.mem.startsWith(u8, path, "~/")) return path;
    const dir = home(ctx) orelse return ctx.fail("{s}: no HOME to expand ~ with", .{path});
    return std.mem.concat(ctx.arena, u8, &.{ dir, path[1..] });
}

// Finding repositories.

const Found = struct {
    /// The path below its root, or the root's name when the root is the repository.
    name: []const u8,
    path: []const u8,
};

/// The repositories under `settings.roots`, by name.
fn discover(ctx: *cli.Context, settings: Settings) ![]Found {
    var found: std.ArrayList(Found) = .empty;
    for (settings.roots) |root_as_given| {
        const root_path = try expandHome(ctx, root_as_given);
        var dir = Io.Dir.cwd().openDir(ctx.io, root_path, .{ .iterate = true }) catch |err| {
            ctx.warn("{s}: {t}", .{ root_as_given, err });
            continue;
        };
        defer dir.close(ctx.io);
        try walk(ctx, dir, root_path, "", settings.depth, settings.ignore, &found);
    }
    std.mem.sort(Found, found.items, {}, struct {
        fn less(_: void, a: Found, b: Found) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    return found.items;
}

fn walk(
    ctx: *cli.Context,
    dir: Io.Dir,
    path: []const u8,
    name: []const u8,
    depth: u8,
    ignore: []const []const u8,
    found: *std.ArrayList(Found),
) !void {
    if (dir.access(ctx.io, ".git", .{})) |_| {
        const shown = if (name.len > 0) name else std.fs.path.basename(path);
        return found.append(ctx.arena, .{ .name = shown, .path = path });
    } else |_| {}
    if (depth == 0) return;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (for (ignore) |pattern| {
            if (cfg.glob(pattern, entry.name)) break true;
        } else false) continue;
        const child_name = if (name.len == 0)
            try ctx.arena.dupe(u8, entry.name)
        else
            try platform.files.join(ctx.arena, name, entry.name);
        const child_path = try platform.files.join(ctx.arena, path, entry.name);
        var child = dir.openDir(ctx.io, entry.name, .{ .iterate = true }) catch continue;
        defer child.close(ctx.io);
        try walk(ctx, child, child_path, child_name, depth - 1, ignore, found);
    }
}

// One repository's state.

pub const Repo = struct {
    name: []const u8,
    branch: []const u8,
    ahead: u32 = 0,
    behind: u32 = 0,
    /// Files changed, staged, or untracked.
    dirty: u32 = 0,
    upstream: ?[]const u8 = null,
    path: []const u8,

    /// `list -o text` shows these; JSON and YAML have every field.
    pub const text_columns = .{
        .name = "NAME",
        .branch = "BRANCH",
        .ahead = "AHEAD",
        .behind = "BEHIND",
        .dirty = "CHANGES",
    };
};

/// What `git status --porcelain=v1 --branch` says.
const Status = struct {
    branch: []const u8 = "",
    upstream: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    /// The lines after the first: `XY path`.
    changes: []const u8 = "",
    dirty: u32 = 0,
};

fn parseStatus(text: []const u8) Status {
    var status: Status = .{};
    const first_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const first = text[0..first_end];
    status.changes = std.mem.trimEnd(u8, text[@min(first_end + 1, text.len)..], "\n");
    if (status.changes.len > 0) {
        status.dirty = @intCast(std.mem.count(u8, status.changes, "\n") + 1);
    }
    if (!std.mem.startsWith(u8, first, "## ")) return status;
    var head = first[3..];
    for ([_][]const u8{ "No commits yet on ", "Initial commit on " }) |prefix| {
        if (std.mem.startsWith(u8, head, prefix)) {
            status.branch = head[prefix.len..];
            return status;
        }
    }
    if (std.mem.startsWith(u8, head, "HEAD (no branch)")) {
        status.branch = "(detached)";
        return status;
    }
    if (std.mem.indexOf(u8, head, " [")) |open| {
        var parts = std.mem.splitSequence(u8, std.mem.trimEnd(u8, head[open + 2 ..], "]"), ", ");
        while (parts.next()) |part| {
            if (std.mem.startsWith(u8, part, "ahead ")) {
                status.ahead = std.fmt.parseInt(u32, part[6..], 10) catch 0;
            } else if (std.mem.startsWith(u8, part, "behind ")) {
                status.behind = std.fmt.parseInt(u32, part[7..], 10) catch 0;
            }
        }
        head = head[0..open];
    }
    if (std.mem.indexOf(u8, head, "...")) |dots| {
        status.branch = head[0..dots];
        status.upstream = head[dots + 3 ..];
    } else status.branch = head;
    return status;
}

/// A repository's state, with its details for the interface.
const Entry = struct {
    repo: Repo,
    status: Status,
    /// `abc1234 subject (2 days ago)`; empty without commits.
    last_commit: []const u8 = "",
};

/// Runs `job(context, i)` for every `i` below `n`, `concurrency` at a time, where the `Io`
/// can; one after another where it cannot.
fn forEach(io: Io, n: usize, concurrency: usize, context: anytype, comptime job: anytype) void {
    const Shared = struct {
        next: std.atomic.Value(usize) = .init(0),
        n: usize,
        context: @TypeOf(context),

        fn work(s: *@This()) Io.Cancelable!void {
            while (true) {
                const i = s.next.fetchAdd(1, .monotonic);
                if (i >= s.n) return;
                job(s.context, i);
            }
        }
    };
    var shared: Shared = .{ .n = n, .context = context };
    var group: Io.Group = .init;
    var started: usize = 1;
    while (started < @min(concurrency, n)) : (started += 1) {
        group.concurrent(io, Shared.work, .{&shared}) catch break;
    }
    Shared.work(&shared) catch {};
    group.await(io) catch {};
}

/// Runs git in `path`; its output in `gpa`, null when it could not start or failed.
fn git(gpa: Allocator, io: Io, path: []const u8, args: []const []const u8) ?[]u8 {
    var argv: [8][]const u8 = undefined;
    argv[0..3].* = .{ "git", "-C", path };
    @memcpy(argv[3..][0..args.len], args);
    const output = platform.process.capture(gpa, io, argv[0 .. 3 + args.len], .{
        .timeout = .fromSeconds(30),
    }) catch return null;
    defer gpa.free(output.stderr);
    if (!output.success()) {
        gpa.free(output.stdout);
        return null;
    }
    return output.stdout;
}

const Gather = struct {
    ctx: *cli.Context,
    found: []const Found,
    entries: []Entry,
    last_commit: bool,
    /// Guards `ctx.arena` and `ctx.err`.
    lock: Io.Mutex = .init,

    fn one(g: *Gather, i: usize) void {
        const ctx = g.ctx;
        const at = g.found[i];
        const status_args = [_][]const u8{ "status", "--porcelain=v1", "--branch" };
        const status_text = git(ctx.gpa, ctx.io, at.path, &status_args);
        defer if (status_text) |t| ctx.gpa.free(t);
        const commit_text = if (g.last_commit)
            git(ctx.gpa, ctx.io, at.path, &.{ "log", "-1", "--format=%h %s (%cr)" })
        else
            null;
        defer if (commit_text) |t| ctx.gpa.free(t);

        g.lock.lockUncancelable(ctx.io);
        defer g.lock.unlock(ctx.io);
        const entry = &g.entries[i];
        entry.* = .{ .repo = .{ .name = at.name, .branch = "?", .path = at.path }, .status = .{} };
        const text = status_text orelse return ctx.warn("{s}: git status failed", .{at.path});
        const status = parseStatus(ctx.arena.dupe(u8, text) catch return);
        entry.status = status;
        entry.repo.branch = status.branch;
        entry.repo.upstream = status.upstream;
        entry.repo.ahead = status.ahead;
        entry.repo.behind = status.behind;
        entry.repo.dirty = status.dirty;
        if (commit_text) |t| {
            entry.last_commit = ctx.arena.dupe(u8, std.mem.trimEnd(u8, t, "\n")) catch "";
        }
    }
};

fn gather(ctx: *cli.Context, settings: Settings, last_commit: bool) ![]Entry {
    const found = try discover(ctx, settings);
    const entries = try ctx.arena.alloc(Entry, found.len);
    var g: Gather = .{ .ctx = ctx, .found = found, .entries = entries, .last_commit = last_commit };
    forEach(ctx.io, found.len, settings.fetch.concurrency, &g, Gather.one);
    return entries;
}

// list

fn listRepos(ctx: *cli.Context) !void {
    const settings = try settingsWithRoots(ctx);
    const entries = try gather(ctx, settings, false);
    const repos = try ctx.arena.alloc(Repo, entries.len);
    for (entries, repos) |entry, *repo| repo.* = entry.repo;
    try ctx.render(@as([]const Repo, repos));
}

// fetch

const FetchFlags = struct {
    roots: []const []const u8 = &.{},
    concurrency: ?u8 = null,
    pub const meta = .{
        .roots = Search.meta.roots,
        .concurrency = .{
            .short = 'j',
            .help = "Repositories to fetch at once",
            .min = 1,
            .key = "fetch.concurrency",
        },
    };
};

const Fetching = struct {
    ctx: *cli.Context,
    found: []const Found,
    steps: []term.live.Steps.Step,
    bar: *term.live.Bar,
    display: *term.live.Live,
    timeout: cfg.Duration,
    failures: usize = 0,

    fn one(f: *Fetching, i: usize) void {
        const ctx = f.ctx;
        f.update(i, .running, "");
        const output = platform.process.capture(ctx.gpa, ctx.io, &.{
            "git", "-C", f.found[i].path, "fetch", "--quiet",
        }, .{ .timeout = f.timeout.toIo() });
        const result = output catch |err| return f.update(i, .failed, @errorName(err));
        defer result.deinit(ctx.gpa);
        if (result.success()) return f.update(i, .done, "");
        const message = std.mem.trim(u8, result.stderr, " \n");
        const line = message[0 .. std.mem.indexOfScalar(u8, message, '\n') orelse message.len];
        f.update(i, .failed, line);
    }

    const Change = struct {
        f: *Fetching,
        i: usize,
        state: term.live.Steps.State,
        note: []const u8,

        /// Runs under the display's lock, which every fetching task shares.
        fn apply(c: Change) void {
            const f = c.f;
            f.steps[c.i].state = c.state;
            f.steps[c.i].note = f.ctx.arena.dupe(u8, c.note) catch "";
            if (c.state == .done or c.state == .failed) f.bar.add(1);
            if (c.state == .failed) f.failures += 1;
        }
    };

    fn update(f: *Fetching, i: usize, state: term.live.Steps.State, note: []const u8) void {
        const change: Change = .{ .f = f, .i = i, .state = state, .note = note };
        f.display.update(f.ctx.io, change, Change.apply) catch {};
    }
};

fn fetch(ctx: *cli.Context) !void {
    const settings = try settingsWithRoots(ctx);
    const found = try discover(ctx, settings);
    const steps = try ctx.arena.alloc(term.live.Steps.Step, found.len);
    for (steps, found) |*step, at| step.* = .{ .name = at.name };
    var list_item: term.live.Steps = .{ .items = steps };
    var bar: term.live.Bar = .{ .label = "fetch", .total = found.len, .show_count = true };
    const items = [_]term.live.Item{ .{ .steps = &list_item }, .{ .bar = &bar } };
    var display = ctx.live(&items);
    try display.draw(.now(ctx.io, .awake));
    display.start(ctx.io) catch {};
    var f: Fetching = .{
        .ctx = ctx,
        .found = found,
        .steps = steps,
        .bar = &bar,
        .display = &display,
        .timeout = settings.fetch.timeout,
    };
    forEach(ctx.io, found.len, settings.fetch.concurrency, &f, Fetching.one);
    bar.finish(if (f.failures == 0) .success else .failure);
    try display.finish(.now(ctx.io, .awake));
    if (f.failures > 0) {
        return ctx.fail("{d} of {d} repositories failed to fetch", .{ f.failures, found.len });
    }
    try ctx.out.print("fetched {d} repositories\n", .{found.len});
}

// ui

const Action = enum { quit, up, down, filter, details_up, details_down };

const keys: tui.Keymap(Action) = .{ .bindings = &.{
    .{ .keys = &.{ "up", "k" }, .action = .up, .help = "move", .label = "↑/↓" },
    .{ .keys = &.{ "down", "j" }, .action = .down },
    .{ .keys = &.{"/"}, .action = .filter, .help = "filter" },
    .{
        .keys = &.{ "pgdown", "ctrl+d" },
        .action = .details_down,
        .help = "details",
        .label = "pgup/pgdn",
    },
    .{ .keys = &.{ "pgup", "ctrl+u" }, .action = .details_up },
    .{ .keys = &.{ "q", "esc" }, .action = .quit, .help = "quit" },
} };

const columns = [_]Table.Column{
    .{ .title = "Repository" },
    .{ .title = "Branch" },
    .{ .title = "Sync" },
    .{ .title = "Changes", .@"align" = .end },
};

/// The repositories in a table to filter, beside the chosen one's details.
pub const Dashboard = struct {
    gpa: Allocator,
    entries: []const Entry,
    /// Per entry: its table cells, and its details.
    cells: []const [columns.len][]const u8,
    details: []const []const u8,
    /// The rows shown: the entries matching the filter, best first.
    shown: std.ArrayList(usize) = .empty,
    rows: std.ArrayList([]const []const u8) = .empty,
    query: Input,
    filtering: bool = false,
    table: Table = .{ .columns = &columns, .rows = &.{}, .top = 2 },
    detail: Viewport = .{ .keys = false, .width = 46 },
    width: u16 = 80,
    height: u16 = 24,

    const panel_width = 48;
    const header: tui.Style = .{ .fg = .hex(0xff8700), .bold = true };
    const muted: tui.Style = .{ .fg = .{ .indexed = 245 } };
    const panel: tui.Style = .{ .border = .rounded, .padding = .symmetric(0, 1) };

    /// `arena` holds the cells and details; `entries` must outlive the dashboard.
    pub fn init(gpa: Allocator, arena: Allocator, entries: []const Entry) !Dashboard {
        const cells = try arena.alloc([columns.len][]const u8, entries.len);
        const details = try arena.alloc([]const u8, entries.len);
        for (entries, cells, details) |entry, *row, *detail| {
            const repo = entry.repo;
            const sync = if (repo.upstream == null)
                "-"
            else if (repo.ahead == 0 and repo.behind == 0)
                "="
            else
                try std.fmt.allocPrint(arena, "↑{d} ↓{d}", .{ repo.ahead, repo.behind });
            const changes = if (repo.dirty == 0)
                ""
            else
                try std.fmt.allocPrint(arena, "{d}", .{repo.dirty});
            row.* = .{ repo.name, repo.branch, sync, changes };
            detail.* = try describe(arena, entry);
        }
        var d: Dashboard = .{
            .gpa = gpa,
            .entries = entries,
            .cells = cells,
            .details = details,
            .query = .{
                .gpa = gpa,
                .prompt = "/ ",
                .placeholder = "type to filter",
                .focused = false,
            },
        };
        try d.refilter();
        return d;
    }

    pub fn deinit(d: *Dashboard) void {
        d.shown.deinit(d.gpa);
        d.rows.deinit(d.gpa);
        d.query.deinit();
    }

    /// The details of one repository, as the pane shows them.
    fn describe(arena: Allocator, entry: Entry) ![]const u8 {
        var out: Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        const repo = entry.repo;
        try w.print("{s}\n\n", .{repo.path});
        try w.print("branch   {s}", .{repo.branch});
        if (repo.upstream) |up| try w.print(" → {s}", .{up});
        try w.writeAll("\nsync     ");
        if (repo.upstream == null) {
            try w.writeAll("no upstream");
        } else if (repo.ahead == 0 and repo.behind == 0) {
            try w.writeAll("up to date");
        } else try w.print("{d} ahead, {d} behind", .{ repo.ahead, repo.behind });
        if (entry.last_commit.len > 0) try w.print("\nlast     {s}", .{entry.last_commit});
        if (repo.dirty == 0) {
            try w.writeAll("\nchanges  none");
        } else try w.print("\nchanges  {d}\n{s}", .{ repo.dirty, entry.status.changes });
        return out.written();
    }

    /// Shows the entries matching the filter, best match first.
    fn refilter(d: *Dashboard) Allocator.Error!void {
        const Scored = struct { index: usize, score: i32 };
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(d.gpa);
        for (d.entries, 0..) |entry, i| {
            const points = fuzzy.score(d.query.value(), entry.repo.name, null) orelse continue;
            try scored.append(d.gpa, .{ .index = i, .score = points });
        }
        std.mem.sort(Scored, scored.items, {}, struct {
            fn more(_: void, a: Scored, b: Scored) bool {
                return a.score > b.score or (a.score == b.score and a.index < b.index);
            }
        }.more);
        d.shown.clearRetainingCapacity();
        d.rows.clearRetainingCapacity();
        for (scored.items) |s| {
            try d.shown.append(d.gpa, s.index);
            try d.rows.append(d.gpa, &d.cells[s.index]);
        }
        d.table.rows = d.rows.items;
        d.table.offset = 0;
        d.table.moveTo(0);
        d.showDetails();
    }

    fn showDetails(d: *Dashboard) void {
        const index = if (d.shown.items.len == 0) null else d.shown.items[d.table.cursor];
        d.detail.setContent(if (index) |i| d.details[i] else "No repository matches.");
        d.detail.offset = 0;
    }

    /// The chosen repository, if any.
    pub fn selected(d: *const Dashboard) ?*const Entry {
        if (d.shown.items.len == 0) return null;
        return &d.entries[d.shown.items[d.table.cursor]];
    }

    pub fn update(d: *Dashboard, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .resize => |size| {
                d.width = size.width;
                d.height = size.height;
                // Header, a blank line, the table's borders and title row, the help line.
                d.table.height = @max(3, @as(usize, size.height) -| 7);
                d.detail.height = @max(3, @as(usize, size.height) -| 6);
                d.table.moveTo(d.table.cursor);
            },
            .key => |key| {
                if (d.filtering) return d.filterKey(key);
                const action = keys.match(key) orelse return .none;
                switch (action) {
                    .quit => return .quit,
                    .up, .down => {
                        d.table.moveBy(if (action == .up) -1 else 1);
                        d.showDetails();
                    },
                    .filter => {
                        d.filtering = true;
                        d.query.focused = true;
                    },
                    .details_up => d.detail.scrollBy(-@as(isize, @intCast(d.detail.height))),
                    .details_down => d.detail.scrollBy(@intCast(d.detail.height)),
                }
            },
            .paste => |text| if (d.filtering) {
                d.query.insert(text) catch {};
                d.refilter() catch {};
            },
            else => {},
        }
        return .none;
    }

    /// Keys while the filter has focus: text edits it, up/down still move, enter keeps
    /// it, esc clears it.
    fn filterKey(d: *Dashboard, key: tui.input.Key) tui.Cmd {
        if (key.matches("enter") or key.matches("esc")) {
            if (key.matches("esc")) d.query.setValue("") catch {};
            d.filtering = false;
            d.query.focused = false;
        } else if (key.matches("up") or key.matches("down")) {
            d.table.moveBy(if (key.matches("up")) -1 else 1);
            d.showDetails();
            return .none;
        } else {
            _ = d.query.handleKey(key);
        }
        d.refilter() catch {};
        return .none;
    }

    pub fn view(d: *const Dashboard, w: *Io.Writer) Io.Writer.Error!void {
        try header.paint(w, "◆ repos");
        try w.print("  {d} of {d}  ", .{ d.shown.items.len, d.entries.len });
        if (d.filtering or d.query.value().len > 0) try d.query.view(w);
        try w.writeAll("\n\n");
        var buffers: [3][16 * 1024]u8 = undefined;
        var table: Io.Writer = .fixed(&buffers[0]);
        try d.table.view(&table);
        var detail: Io.Writer = .fixed(&buffers[1]);
        try d.detail.view(&detail);
        var boxed: Io.Writer = .fixed(&buffers[2]);
        var box = panel;
        box.width = panel_width;
        try box.render(&boxed, std.mem.trimEnd(u8, detail.buffered(), "\n"));
        const blocks = [_][]const u8{ table.buffered(), " ", boxed.buffered() };
        try tui.layout.joinHorizontal(w, .start, &blocks);
        try w.writeAll("\n");
        try keys.writeHelp(w, .{});
    }
};

const UiFlags = struct {
    roots: []const []const u8 = &.{},
    web: ?[]const u8 = null,
    snapshot: bool = false,
    pub const meta = .{
        .roots = Search.meta.roots,
        .web = .{ .value_name = "host:port", .help = "Serve the interface to browsers on " ++
            "this address instead (open the link it prints, token and all)" },
        .snapshot = .{ .help = "Print the first screen as text, and quit" },
    };
};

fn ui(ctx: *cli.Context, flags: UiFlags) !void {
    const settings = try settingsWithRoots(ctx);
    const entries = try gather(ctx, settings, true);
    if (flags.web) |address| return serveWeb(ctx, entries, address);
    var dashboard: Dashboard = try .init(ctx.gpa, ctx.arena, entries);
    defer dashboard.deinit();
    const status = try tui.run(ctx.gpa, ctx.io, &dashboard, .{
        .environ = ctx.environ,
        .program = .{ .alt_screen = true },
        // No terminal: the first screen, on a virtual one, as text.
        .snapshot = flags.snapshot,
        .snapshot_out = ctx.out,
        .snapshot_size = .{ .width = 100, .height = 20 },
    });
    if (status != 0) return ctx.exit(status);
}

const Served = struct {
    gpa: Allocator,
    io: Io,
    entries: []const Entry,
};

fn serveWeb(ctx: *cli.Context, entries: []const Entry, text: []const u8) !void {
    const address = Io.net.IpAddress.parseLiteral(text) catch
        return ctx.usageError("--web {s}: give host:port, such as 127.0.0.1:7681", .{text});
    var listener = address.listen(ctx.io, .{ .reuse_address = true }) catch |err|
        return ctx.fail("--web {s}: {t}", .{ text, err });
    defer listener.deinit(ctx.io);
    var served: Served = .{ .gpa = ctx.gpa, .io = ctx.io, .entries = entries };
    const token = web.Server.newToken(ctx.io);
    const config: web.Server.Config = .{
        .handler = web.Server.handlerFor(Served, visit),
        .context = &served,
        .token = &token,
        .title = "repos",
    };
    try ctx.err.print("serving {d} repositories on {f}\n", .{
        entries.len, web.Server.link(listener.socket.address, &config),
    });
    web.Server.serve(ctx.gpa, ctx.io, &listener, &config) catch |err|
        return ctx.fail("--web {s}: {t}", .{ text, err });
}

/// One browser tab: its own dashboard over the same repositories.
fn visit(served: *Served, session: *web.Session) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(served.gpa);
    defer arena_state.deinit();
    var dashboard: Dashboard = try .init(served.gpa, arena_state.allocator(), served.entries);
    defer dashboard.deinit();
    _ = try tui.runSession(served.gpa, served.io, &dashboard, session, .{ .alt_screen = true });
}

// The command tree.

pub const root = cli.command(.{
    .name = "repos",
    .summary = "The git repositories on this machine, at a glance",
    .persistent_flags = Global,
    .logging = true,
    .subcommands = .{
        cli.command(.{
            .name = "setup",
            .summary = "Choose where to look for repositories, and write the configuration",
            .flags = Setup,
            .dry_run = true,
            .output = true,
            .examples =
            \\repos setup
            \\repos setup --roots ~/work,~/oss --no-usual --concurrency 8
            ,
            .run = runSetup,
        }),
        cli.command(.{
            .name = "list",
            .aliases = &.{"ls"},
            .summary = "List the repositories: branch, changes, ahead and behind",
            .flags = Search,
            .output = true,
            .examples =
            \\repos list
            \\repos list -o jsonl | jq -r 'select(.dirty > 0) | .path'
            ,
            .run = listRepos,
        }),
        cli.command(.{
            .name = "fetch",
            .summary = "Fetch every repository, several at once",
            .flags = FetchFlags,
            .run = fetch,
        }),
        cli.command(.{
            .name = "ui",
            .summary = "Browse the repositories: filter with /, details beside",
            .flags = UiFlags,
            .run = ui,
        }),
    },
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root };
    return app.run(init);
}

// Tests.

const testing = std.testing;
const test_app: cli.App = .{ .root = &root };

test parseStatus {
    const s = parseStatus("## main...origin/main [ahead 2, behind 1]\n M a.zig\n?? b\n");
    try testing.expectEqualStrings("main", s.branch);
    try testing.expectEqualStrings("origin/main", s.upstream.?);
    try testing.expectEqual(2, s.ahead);
    try testing.expectEqual(1, s.behind);
    try testing.expectEqual(2, s.dirty);
    try testing.expectEqualStrings(" M a.zig\n?? b", s.changes);
    try testing.expectEqualStrings("trunk", parseStatus("## No commits yet on trunk\n").branch);
    try testing.expectEqualStrings("(detached)", parseStatus("## HEAD (no branch)\n").branch);
    const plain = parseStatus("## dev\n");
    try testing.expectEqualStrings("dev", plain.branch);
    try testing.expectEqual(null, plain.upstream);
    try testing.expectEqual(0, plain.dirty);
    try testing.expectEqual(3, parseStatus("## x...y [behind 3]\n").behind);
}

/// A directory of repositories made with git: `origin` (one commit), `work/api` (a clone,
/// a commit ahead, a file changed), `work/web` (a clone, clean), and `node_modules/dep`
/// (ignored), plus a plain directory.
const Fixture = struct {
    tmp: testing.TmpDir,
    path: [:0]const u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(path);
        var f: Fixture = .{ .tmp = tmp, .path = path };
        try f.run(&.{ "init", "-q", "-b", "main", "origin" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "origin/README", .data = "hi\n" });
        try f.run(&.{ "-C", "origin", "add", "README" });
        try f.commit("origin", "first");
        try tmp.dir.createDirPath(testing.io, "work");
        try tmp.dir.createDirPath(testing.io, "notes/plain");
        try f.run(&.{ "clone", "-q", "origin", "work/api" });
        try f.run(&.{ "clone", "-q", "origin", "work/web" });
        try f.run(&.{ "init", "-q", "node_modules/dep" });
        try f.commit("work/api", "second");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "work/api/README", .data = "changed\n" });
        return f;
    }

    fn deinit(f: *Fixture) void {
        testing.allocator.free(f.path);
        f.tmp.cleanup();
    }

    fn commit(f: *Fixture, repo: []const u8, message: []const u8) !void {
        try f.run(&.{
            "-C",     repo, "-c", "user.name=t", "-c",            "user.email=t@example.com",
            "commit", "-q", "-m", message,       "--allow-empty",
        });
    }

    fn run(f: *Fixture, args: []const []const u8) !void {
        var argv: [16][]const u8 = undefined;
        argv[0..3].* = .{ "git", "-C", f.path };
        @memcpy(argv[3..][0..args.len], args);
        const argv_used = argv[0 .. 3 + args.len];
        const output = try platform.process.capture(testing.allocator, testing.io, argv_used, .{});
        defer output.deinit(testing.allocator);
        if (!output.success()) {
            std.debug.print("git {s}: {s}\n", .{ args[0], output.stderr });
            return error.GitFailed;
        }
    }

    /// The environment of a run: no configuration file, and the roots in `REPOS_ROOTS`.
    fn env(f: *const Fixture, buffer: []u8) ![2][2][]const u8 {
        const config = try std.fmt.bufPrint(buffer, "{s}/none.toml", .{f.path});
        return .{ .{ "REPOS_CONFIG", config }, .{ "REPOS_ROOTS", f.path } };
    }
};

test "list finds the repositories, skips the ignored, and says what state each is in" {
    var f: Fixture = try .init();
    defer f.deinit();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const env = try f.env(&buffer);
    const result = try cli.testing.run(test_app, &.{ "list", "-o", "json" }, .{ .env = &env });
    defer result.deinit();
    try testing.expectEqualStrings("", result.err);
    try testing.expectEqual(0, result.status);
    const Parsed = []const Repo;
    const parsed = try std.json.parseFromSlice(Parsed, testing.allocator, result.out, .{});
    defer parsed.deinit();
    const repos = parsed.value;
    try testing.expectEqual(3, repos.len);
    try testing.expectEqualStrings("origin", repos[0].name);
    try testing.expectEqual(null, repos[0].upstream);
    try testing.expectEqualStrings("work/api", repos[1].name);
    try testing.expectEqualStrings("main", repos[1].branch);
    try testing.expectEqualStrings("origin/main", repos[1].upstream.?);
    try testing.expectEqual(1, repos[1].ahead);
    try testing.expectEqual(1, repos[1].dirty);
    try testing.expectEqualStrings("work/web", repos[2].name);
    try testing.expectEqual(0, repos[2].dirty);
}

test "list as text and as JSON lines" {
    var f: Fixture = try .init();
    defer f.deinit();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const env = try f.env(&buffer);
    const text = try cli.testing.run(test_app, &.{"list"}, .{ .env = &env });
    defer text.deinit();
    try testing.expectEqual(0, text.status);
    const header = "NAME      BRANCH  AHEAD  BEHIND  CHANGES\n";
    try testing.expect(std.mem.startsWith(u8, text.out, header));
    const api_row = "\nwork/api  main    1      0       1\n";
    try testing.expect(std.mem.indexOf(u8, text.out, api_row) != null);
    const lines = try cli.testing.run(test_app, &.{ "ls", "-o", "jsonl" }, .{ .env = &env });
    defer lines.deinit();
    try testing.expectEqual(3, std.mem.count(u8, lines.out, "\n"));
    try testing.expect(std.mem.startsWith(u8, lines.out, "{\"name\":\"origin\""));
}

test "--roots and the depth limit decide where to look" {
    var f: Fixture = try .init();
    defer f.deinit();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const env = try f.env(&buffer);
    const work = try std.fmt.allocPrint(testing.allocator, "{s}/work", .{f.path});
    defer testing.allocator.free(work);
    const result = try cli.testing.run(test_app, &.{ "list", "--roots", work, "-o", "jsonl" }, .{
        .env = &.{ env[0], .{ "REPOS_DEPTH", "1" } },
    });
    defer result.deinit();
    try testing.expectEqual(2, std.mem.count(u8, result.out, "\n"));
    try testing.expect(std.mem.indexOf(u8, result.out, "\"name\":\"api\"") != null);
    const shallow = try cli.testing.run(test_app, &.{ "list", "-o", "jsonl" }, .{
        .env = &.{ env[0], env[1], .{ "REPOS_DEPTH", "0" } },
    });
    defer shallow.deinit();
    try testing.expectEqual(1, shallow.status);
    try testing.expect(std.mem.indexOf(u8, shallow.err, "depth") != null);
}

test "without roots, and no terminal to ask at, it says how to give them" {
    const result = try cli.testing.run(test_app, &.{"list"}, .{
        .env = &.{.{ "REPOS_CONFIG", "/nonexistent/repos.toml" }},
    });
    defer result.deinit();
    try result.expect(1, "", "repos: no roots to search: run repos setup, set REPOS_ROOTS, " ++
        "or pass --roots\n");
}

test "fetch fetches every repository and reports each" {
    var f: Fixture = try .init();
    defer f.deinit();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const env = try f.env(&buffer);
    const result = try cli.testing.run(test_app, &.{ "fetch", "-j", "2" }, .{ .env = &env });
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expectEqualStrings("fetched 3 repositories\n", result.out);
    for ([_][]const u8{ "✓ origin", "✓ work/api", "✓ work/web", "✓ fetch" }) |line| {
        errdefer std.debug.print("missing {s} in:\n{s}\n", .{ line, result.err });
        try testing.expect(std.mem.indexOf(u8, result.err, line) != null);
    }
}

test "a repository that cannot fetch fails the command, named" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.run(&.{ "-C", "work/web", "remote", "set-url", "origin", "/nonexistent/repo" });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const env = try f.env(&buffer);
    const result = try cli.testing.run(test_app, &.{"fetch"}, .{ .env = &env });
    defer result.deinit();
    try testing.expectEqual(1, result.status);
    try testing.expect(std.mem.indexOf(u8, result.err, "✗ work/web") != null);
    try testing.expect(std.mem.indexOf(u8, result.err, "1 of 3 repositories failed") != null);
}

test "setup asks, counts, and writes the configuration, then list reads it" {
    var f: Fixture = try .init();
    defer f.deinit();
    const config = try std.fmt.allocPrint(testing.allocator, "{s}/conf/repos.toml", .{f.path});
    defer testing.allocator.free(config);
    // The roots, then the concurrency; the usual places are not offered (no HOME).
    const answers = try std.fmt.allocPrint(testing.allocator, "{s}/work\n8\n", .{f.path});
    defer testing.allocator.free(answers);
    const args = [_][]const u8{ "setup", "-c", config };
    const result = try cli.testing.run(test_app, &args, .{ .stdin = answers });
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expect(std.mem.indexOf(u8, result.err, "2 repositories under") != null);
    try testing.expect(std.mem.endsWith(u8, result.out, "repos.toml\n"));
    const written = try readFile(config);
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "concurrency = 8") != null);

    const listed = try cli.testing.run(test_app, &.{ "list", "-c", config, "-o", "jsonl" }, .{});
    defer listed.deinit();
    try testing.expectEqual(2, std.mem.count(u8, listed.out, "\n"));
}

test "setup from flags keeps the file's comments and other settings" {
    var f: Fixture = try .init();
    defer f.deinit();
    const config = try std.fmt.allocPrint(testing.allocator, "{s}/repos.toml", .{f.path});
    defer testing.allocator.free(config);
    try f.tmp.dir.writeFile(testing.io, .{
        .sub_path = "repos.toml",
        .data = "# mine\ndepth = 2\nroots = [\"/old\"]\n",
    });
    const result = try cli.testing.run(test_app, &.{
        "setup", "-c", config, "--roots", f.path, "--no-usual", "--concurrency", "3",
    }, .{});
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    const written = try readFile(config);
    defer testing.allocator.free(written);
    try testing.expect(std.mem.startsWith(u8, written, "# mine\ndepth = 2\n"));
    try testing.expect(std.mem.indexOf(u8, written, "/old") == null);
    try testing.expect(std.mem.indexOf(u8, written, "concurrency = 3") != null);

    // Run again without the flags, it keeps what the file says.
    const again = try cli.testing.run(test_app, &.{ "setup", "-c", config, "--no-usual" }, .{});
    defer again.deinit();
    try testing.expectEqual(0, again.status);
    const kept = try readFile(config);
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings(written, kept);
}

test "the usual places are offered only when one exists" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, "src");
    const config = try std.fmt.allocPrint(testing.allocator, "{s}/repos.toml", .{f.path});
    defer testing.allocator.free(config);
    const work = try std.fmt.allocPrint(testing.allocator, "{s}/work", .{f.path});
    defer testing.allocator.free(work);
    const result = try cli.testing.run(test_app, &.{
        "setup", "-c", config, "--roots", work, "--dry-run", "-o", "json",
    }, .{ .env = &.{.{ "HOME", f.path }}, .stdin = "y\n\n" });
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expect(std.mem.indexOf(u8, result.err, "Also search ~/src") != null);
    try testing.expect(std.mem.indexOf(u8, result.out, "\"step\":\"save\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.out, "\"outcome\":\"dry_run\"") != null);
    // A dry run writes nothing.
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(testing.io, "repos.toml", .{}));
}

fn readFile(path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
}

const Driver = tui.testing.Driver(Dashboard);

fn testEntries(arena: Allocator) ![]Entry {
    const entries = try arena.alloc(Entry, 3);
    entries[0] = .{
        .repo = .{
            .name = "api",
            .branch = "main",
            .upstream = "origin/main",
            .ahead = 2,
            .dirty = 1,
            .path = "/r/api",
        },
        .status = .{ .changes = " M server.zig" },
        .last_commit = "abc1234 Add the server (2 days ago)",
    };
    entries[1] = .{ .repo = .{ .name = "web", .branch = "dev", .path = "/r/web" }, .status = .{} };
    entries[2] = .{
        .repo = .{ .name = "docs", .branch = "main", .upstream = "origin/main", .path = "/r/docs" },
        .status = .{},
    };
    return entries;
}

test "the dashboard filters as you type and shows the chosen repository's details" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dashboard: Dashboard = try .init(testing.allocator, arena, try testEntries(arena));
    var d: Driver = try .init(testing.allocator, dashboard, .{
        .program = .{ .size = .{ .width = 100, .height = 16 } },
    });
    defer d.deinit();
    try d.expectFrameContains("3 of 3");
    try d.expectFrameContains("2 ahead, 0 behind");
    try d.expectFrameContains("M server.zig");
    try d.press("down");
    try d.expectFrameContains("no upstream");
    try d.press("/");
    try d.typeText("dc");
    try d.expectFrameContains("1 of 3");
    try testing.expectEqualStrings("docs", d.model().selected().?.repo.name);
    try d.expectFrameContains("up to date");
    try d.press("esc");
    try d.expectFrameContains("3 of 3");
    try d.press("/");
    try d.typeText("zzz");
    try d.expectFrameContains("No repository matches.");
    try d.press("enter");
    try d.press("q");
    try testing.expect(d.done());
}

test "ui --snapshot prints the first screen" {
    var f: Fixture = try .init();
    defer f.deinit();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const env = try f.env(&buffer);
    const result = try cli.testing.run(test_app, &.{ "ui", "--snapshot" }, .{ .env = &env });
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expect(std.mem.startsWith(u8, result.out, "◆ repos  3 of 3"));
    try testing.expect(std.mem.indexOf(u8, result.out, "│ work/api") != null);
    try testing.expect(std.mem.indexOf(u8, result.out, "first (") != null);
}

fn serveBrowsers(served: *Served, listener: *Io.net.Server, config: *const web.Server.Config) void {
    web.Server.serve(served.gpa, served.io, listener, config) catch {};
}

test "over a browser's socket: the dashboard, a filter, and leaving" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var served: Served = .{
        .gpa = testing.allocator,
        .io = io,
        .entries = try testEntries(arena_state.allocator()),
    };
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const config: web.Server.Config = .{
        .handler = web.Server.handlerFor(Served, visit),
        .context = &served,
        .token = "",
        .anyone = true,
    };
    var serving = try io.concurrent(serveBrowsers, .{ &served, &listener, &config });
    defer serving.cancel(io);

    var origin: [64]u8 = undefined;
    var client: web.Client = undefined;
    const from = try std.fmt.bufPrint(&origin, "http://{f}", .{listener.socket.address});
    try testing.expectEqual(101, try client.open(io, listener.socket.address, "/ws", from));
    defer client.close();
    try client.send(.text, "{\"type\":\"resize\",\"cols\":100,\"rows\":16}");
    try client.send(.binary, "/web");
    var screen: std.ArrayList(u8) = .empty;
    defer screen.deinit(testing.allocator);
    while (std.mem.indexOf(u8, screen.items, "no upstream") == null) {
        const m = try client.receive();
        try testing.expectEqual(.binary, m.opcode);
        try screen.appendSlice(testing.allocator, m.data);
    }
    try client.send(.binary, "\rq");
    while (true) {
        const m = try client.receive();
        if (m.opcode != .text) continue;
        try testing.expectEqualStrings("{\"type\":\"exit\",\"status\":0}", m.data);
        break;
    }
}
