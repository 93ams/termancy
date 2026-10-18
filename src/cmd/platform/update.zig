//! `snek platform update`: replaces the running snek with the latest GitHub release of
//! 93ams/snek, verified against its published SHA-256 checksum and release signature.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const platform = @import("platform");
const live = @import("term").live;
const version = @import("../../main.zig").version;

const update = platform.update;

const UpdateFlags = struct {
    check: bool = false,
    pub const meta = .{ .check = .{ .help = "Only report whether a newer release exists" } };
};

pub const command = cli.command(.{
    .name = "update",
    .summary = "Update snek to its latest release",
    .description =
    \\Look up the latest release of 93ams/snek on GitHub and, when it is newer than this
    \\snek, download the archive for this OS and architecture (.tar.gz; .zip on Windows),
    \\check it against the release's SHA-256 checksum and Ed25519 signature, unpack snek
    \\from it, and replace the running executable (keeping a rollback copy until the new
    \\one has run `--version`). Pre-releases and drafts are ignored.
    \\
    \\Without --yes, asks for confirmation on the terminal; without one (or under CI) it
    \\refuses instead, before any network access, so a script never waits on a prompt.
    \\-v logs the URLs, the archive chosen, and the checks made.
    ,
    .flags = UpdateFlags,
    .confirm = true,
    .logging = true,
    .exit_statuses = &.{
        .{ .code = 0, .meaning = "Up to date, or updated (with --check: a newer release " ++
            "was found)" },
        .{ .code = 1, .meaning = "The lookup, download, verification, or install failed, " ++
            "or the update was not confirmed" },
    },
    .examples =
    \\snek platform update --check
    \\snek platform update --yes
    ,
    .run = run,
});

/// Where snek's releases are published.
pub const source: update.Source = .{ .owner = "93ams", .repo = "snek" };

/// The public half of the release key (`snek platform release keygen`). Every archive must
/// carry a valid `<archive>.sig` made with its secret half, the SNEK_SIGNING_KEY secret.
const public_key = "Km3RAUtsq/6Nw0K18QyRO/69uUdhz4ezAf3SmC0PPhU=";

/// How long one request may take, connection to last byte.
const timeout: std.Io.Duration = .fromSeconds(60);

/// The executable to replace: `path`, relative to `dir`.
const Destination = struct { dir: std.Io.Dir, path: []const u8 };

fn run(ctx: *cli.Context, flags: UpdateFlags) !void {
    // Without a terminal, refused (or, with --yes, allowed) before any network access; the
    // question is never asked there.
    if (!flags.check and !ctx.interactive) try ctx.confirm("", .{});
    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();
    var http: update.HttpTransport = .{
        .client = &client,
        .timeout = timeout,
        .user_agent = "snek/" ++ version,
    };
    try runWith(ctx, flags, http.transport(), defaultOptions(), null);
}

/// The update options for this build of snek, without an install check.
fn defaultOptions() update.Options {
    return .{
        .source = source,
        .current = comptime platform.version.parse(version) catch unreachable,
        // Releases publish archives: snek-<os>-<cpu>.tar.gz, and .zip for Windows.
        .naming = .{ .suffix = if (builtin.os.tag == .windows) ".zip" else ".tar.gz" },
        .executable_name = "snek",
        .public_key = comptime decodeKey(public_key),
    };
}

fn decodeKey(comptime text: []const u8) [std.crypto.sign.Ed25519.PublicKey.encoded_length]u8 {
    var key: [std.crypto.sign.Ed25519.PublicKey.encoded_length]u8 = undefined;
    std.base64.standard.Decoder.decode(&key, text) catch unreachable;
    return key;
}

/// Checks for an update through `transport` and, unless `flags.check`, installs it at
/// `destination` (null: the running executable, which must then pass `runsVersion`).
fn runWith(
    ctx: *cli.Context,
    flags: UpdateFlags,
    transport: update.Transport,
    options: update.Options,
    destination: ?Destination,
) !void {
    var watched: Watched = .{ .inner = transport, .ctx = ctx };
    const signed = options.public_key != null;
    var phases = [_]live.Steps.Step{
        .{ .name = "look up the latest release" },
        .{ .name = "download" },
        .{ .name = if (signed) "verify the checksum and signature" else "verify the checksum" },
        .{ .name = "install" },
    };
    var lookup: Progress = try .init(ctx, phases[0..1]);
    try lookup.advance(0, .running);
    const found = update.check(ctx.arena, watched.transport(), options) catch |err| {
        try lookup.end(0, .failed);
        return checkFailed(ctx, err);
    };
    try lookup.end(0, .done);
    const plan = switch (found) {
        .up_to_date => |current| return ctx.out.print("snek {f} is up to date\n", .{current}),
        .available => |plan| plan,
    };
    ctx.log(.info, "latest release {s}: {s}, checksum in {s}, signature {s}", .{
        plan.tag,
        plan.binary.name,
        plan.checksum.name,
        if (plan.signature) |sig| sig.name else "none",
    });
    try ctx.out.print("snek {f} is available (this is {f})\n", .{ plan.latest, plan.current });
    if (flags.check) return;
    const target = destination orelse try runningExecutable(ctx);
    var accept: Accept = .{ .gpa = ctx.gpa, .expected = plan.latest };
    var opts = options;
    if (destination == null) opts.install.accept = .{ .context = &accept, .run = runsVersion };
    try ctx.out.flush(); // The question follows the line above.
    try ctx.confirm("Replace {s} with snek {f}?", .{ target.path, plan.latest });
    ctx.log(.info, "replacing {s}", .{target.path});
    update.removeLeftovers(ctx.io, target.dir, target.path) catch {};
    phases[1].name = try std.fmt.allocPrint(ctx.arena, "download {s}", .{plan.binary.name});
    var progress: Progress = try .init(ctx, phases[1..]);
    watched.progress = &progress;
    watched.archive = plan.binary.url;
    try progress.advance(0, .running);
    const fetch = watched.transport();
    update.apply(ctx.gpa, ctx.io, fetch, plan, opts, target.dir, target.path) catch |err| {
        try progress.end(failedStep(err, progress.at), .failed);
        return applyFailed(ctx, plan, err);
    };
    try progress.end(2, .done);
    if (signed) {
        ctx.log(.info, "{s}: checksum and Ed25519 signature verified", .{plan.binary.name});
    }
    try ctx.out.print("updated {s} to snek {f}\n", .{ target.path, plan.latest });
}

/// The step of `apply` that `err` failed: download (0), verify (1), or install (2). A
/// failed request fails the step `running`; a check fails after its download.
fn failedStep(err: update.ApplyError, running: usize) usize {
    return switch (err) {
        error.NotFound, error.FetchFailed, error.Timeout, error.TooLarge => running,
        error.SizeMismatch => 0,
        error.ChecksumMissing,
        error.ChecksumMismatch,
        error.SignatureMissing,
        error.SignatureInvalid,
        error.InvalidPublicKey,
        => 1,
        else => 2,
    };
}

/// Steps on standard error (`ctx.live`): redrawn in place at a terminal, else a line per
/// finished step; nothing with `-q`.
const Progress = struct {
    ctx: *cli.Context,
    steps: *live.Steps,
    display: live.Live,
    /// The step running now.
    at: usize = 0,

    fn init(ctx: *cli.Context, phases: []live.Steps.Step) !Progress {
        const steps = try ctx.arena.create(live.Steps);
        steps.* = .{ .items = phases };
        const items = try ctx.arena.dupe(live.Item, &.{.{ .steps = steps }});
        var display = ctx.live(items);
        // `-v -v` logs each request, which must not land on a line redrawn in place.
        if (ctx.logs(.debug)) display.animate = false;
        return .{ .ctx = ctx, .steps = steps, .display = display };
    }

    /// Moves step `i` to `state`, the steps before it done; a running step shows only
    /// where lines are redrawn in place.
    fn advance(p: *Progress, i: usize, state: live.Steps.State) !void {
        for (p.steps.items[0..i]) |*step| step.state = .done;
        p.steps.items[i].state = state;
        if (state == .running) p.at = i;
        if (state != .running or p.display.animate) try p.display.draw(now(p.ctx));
    }

    /// `advance`, then leaves the steps drawn as they are.
    fn end(p: *Progress, i: usize, state: live.Steps.State) !void {
        try p.advance(i, state);
        try p.display.finish(now(p.ctx));
    }

    fn now(ctx: *cli.Context) std.Io.Timestamp {
        return .now(ctx.io, .awake);
    }
};

/// A transport that logs each request (`-v -v`) and, once `apply` asks for anything but
/// the archive, moves `progress` from the download to the checks.
const Watched = struct {
    inner: update.Transport,
    ctx: *cli.Context,
    progress: ?*Progress = null,
    archive: []const u8 = "",

    fn transport(w: *Watched) update.Transport {
        return .{ .context = w, .getFn = get };
    }

    fn get(
        context: *anyopaque,
        gpa: std.mem.Allocator,
        url: []const u8,
        limit: usize,
    ) update.Transport.Error![]u8 {
        const w: *Watched = @ptrCast(@alignCast(context));
        w.ctx.log(.debug, "GET {s}", .{url});
        if (w.progress) |p| if (p.at == 0 and !std.mem.eql(u8, url, w.archive)) {
            p.advance(1, .running) catch {};
        };
        return w.inner.get(gpa, url, limit);
    }
};

fn runningExecutable(ctx: *cli.Context) !Destination {
    const path = platform.exe.pathAlloc(ctx.io, ctx.arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| return ctx.fail("cannot find the running executable: {t}", .{e}),
    };
    return .{ .dir = .cwd(), .path = path };
}

/// What `runsVersion` needs: the release's version, which the new snek must report.
const Accept = struct { gpa: std.mem.Allocator, expected: platform.version.Version };

/// The install check: the new executable must run `--version` successfully and report the
/// release's version, so an older signed archive published under a newer tag (the signature
/// covers the bytes, not the tag) is not installed as a downgrade.
fn runsVersion(
    context: ?*anyopaque,
    io: std.Io,
    dir: std.Io.Dir,
    exe_path: []const u8,
) error{Rejected}!void {
    const accept: *const Accept = @ptrCast(@alignCast(context.?));
    const gpa = accept.gpa;
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = dir.realPathFile(io, exe_path, &path_buffer) catch return error.Rejected;
    const result = std.process.run(gpa, io, .{
        .argv = &.{ path_buffer[0..len], "--version" },
    }) catch return error.Rejected;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success() or !reports(result.stdout, accept.expected)) return error.Rejected;
}

/// Whether `stdout` of `snek --version` names `expected`: `snek <version>`, then a space,
/// a line end, or nothing.
fn reports(stdout: []const u8, expected: platform.version.Version) bool {
    var buffer: [128]u8 = undefined;
    const want = std.fmt.bufPrint(&buffer, "snek {f}", .{expected}) catch return false;
    if (!std.mem.startsWith(u8, stdout, want)) return false;
    const rest = stdout[want.len..];
    return rest.len == 0 or rest[0] == ' ' or rest[0] == '\n' or rest[0] == '\r';
}

test reports {
    const v = try platform.version.parse("1.2.0");
    try testing.expect(reports("snek 1.2.0\n", v));
    try testing.expect(reports("snek 1.2.0 (abc1234, 2026-10-17)\n", v));
    try testing.expect(!reports("snek 1.1.0\n", v)); // An older release, re-tagged.
    try testing.expect(!reports("snek 1.2.0-rc.1\n", v));
    try testing.expect(!reports("snek 1.2.01\n", v));
    try testing.expect(!reports("other 1.2.0\n", v));
}

const repo = source.owner ++ "/" ++ source.repo;
const target_name = @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.cpu.arch);

/// Failures as `checkFailed` and `applyFailed` report them.
const Reported = cli.Context.Failure || std.mem.Allocator.Error;

fn checkFailed(ctx: *cli.Context, err: update.CheckError) Reported {
    return switch (err) {
        error.NotFound => ctx.fail("no release of " ++ repo ++ " found: none is published " ++
            "yet (GitHub answered 404 Not Found)", .{}),
        error.FetchFailed => ctx.fail("cannot look up the latest release of " ++ repo ++
            ": connection or HTTP error", .{}),
        error.Timeout => ctx.fail("timed out looking up the latest release of " ++ repo, .{}),
        error.TooLarge => ctx.fail("the latest release of " ++ repo ++
            " is too large to read", .{}),
        error.InvalidRelease => ctx.fail("the latest release of " ++ repo ++
            " could not be read", .{}),
        error.InvalidVersion => ctx.fail("the latest release of " ++ repo ++
            " is not tagged with a semantic version", .{}),
        error.NoMatchingAsset => ctx.fail("the latest release of " ++ repo ++
            " has no build for " ++ target_name, .{}),
        error.AmbiguousAsset => ctx.fail("the latest release of " ++ repo ++
            " has more than one build for " ++ target_name, .{}),
        error.ChecksumMissing => ctx.fail("the latest release of " ++ repo ++
            " publishes no checksum; not installing it", .{}),
        error.InvalidSource => unreachable, // `source` is a valid constant.
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn applyFailed(ctx: *cli.Context, plan: update.Plan, err: update.ApplyError) Reported {
    const name = plan.binary.name;
    return switch (err) {
        error.NotFound, error.FetchFailed => ctx.fail("cannot download {s}", .{name}),
        error.Timeout => ctx.fail("timed out downloading {s}", .{name}),
        error.TooLarge, error.SizeMismatch => ctx.fail("{s}: unexpected size; not installed", .{
            name,
        }),
        error.ChecksumMissing => ctx.fail("the checksum file does not list {s}; not installed", .{
            name,
        }),
        error.ChecksumMismatch => ctx.fail("{s} does not match its checksum; not installed", .{
            name,
        }),
        error.SignatureMissing,
        error.SignatureInvalid,
        error.InvalidPublicKey,
        => ctx.fail("{s}: bad signature; not installed", .{name}),
        error.ArchiveInvalid => ctx.fail("cannot unpack {s}; not installed", .{name}),
        error.ExecutableMissing => ctx.fail("{s} holds no snek executable; not installed", .{
            name,
        }),
        error.Rejected => ctx.fail("the new snek does not run as snek {f}; the old one " ++
            "was restored", .{plan.latest}),
        error.RollbackFailed => ctx.fail("the update failed and so did restoring the old " ++
            "executable; it is left next to the new one, with .old appended", .{}),
        error.NameTooLong,
        error.StageFailed,
        error.BackupFailed,
        error.SwapFailed,
        => |e| ctx.fail("cannot install the update: {t}; nothing was changed", .{e}),
        error.OutOfMemory => error.OutOfMemory,
    };
}

// Tests: the whole flow over an in-memory transport, so nothing touches the network.

const testing = std.testing;

/// URL-to-body routes; any other URL is answered 404.
const MemoryTransport = struct {
    routes: []const [2][]const u8,
    requests: usize = 0,

    fn transport(memory: *MemoryTransport) update.Transport {
        return .{ .context = memory, .getFn = get };
    }

    fn get(
        context: *anyopaque,
        gpa: std.mem.Allocator,
        url: []const u8,
        limit: usize,
    ) update.Transport.Error![]u8 {
        const memory: *MemoryTransport = @ptrCast(@alignCast(context));
        memory.requests += 1;
        for (memory.routes) |route| {
            if (!std.mem.eql(u8, route[0], url)) continue;
            if (route[1].len > limit) return error.TooLarge;
            return gpa.dupe(u8, route[1]);
        }
        return error.NotFound;
    }
};

const latest_url = "https://api.github.com/repos/93ams/snek/releases/latest";
/// The tests publish a `.tar.gz` on every OS, so one archive builder serves them all.
const asset_name = "snek-" ++ target_name ++ ".tar.gz";
const new_binary = "new snek";

fn testOptions() update.Options {
    var options = defaultOptions();
    options.naming.suffix = ".tar.gz";
    options.public_key = null;
    return options;
}

/// A `.tar.gz` holding `snek`, stored without compression, in `arena`.
fn testArchive(arena: std.mem.Allocator) ![]const u8 {
    var tar_bytes: std.Io.Writer.Allocating = .init(arena);
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_bytes.writer };
    try tar.writeFileBytes("snek", new_binary, .{ .mode = 0o755 });
    try tar_bytes.writer.splatByteAll(0, 1024); // The end-of-archive marker.
    var out: std.Io.Writer.Allocating = .init(arena);
    const buffer = try arena.alloc(u8, std.compress.flate.max_window_len);
    var gzip: std.compress.flate.Compress.Raw = try .init(&out.writer, buffer, .gzip);
    try gzip.writer.writeAll(tar_bytes.written());
    try gzip.finish();
    return out.written();
}

fn releaseJson(comptime tag: []const u8) []const u8 {
    return "{\"tag_name\": \"" ++ tag ++ "\", \"assets\": [" ++
        "{\"name\": \"" ++ asset_name ++ "\", " ++
        "\"browser_download_url\": \"https://dl/" ++ asset_name ++ "\"}, " ++
        "{\"name\": \"SHA256SUMS\", \"browser_download_url\": \"https://dl/SHA256SUMS\"}]}";
}

/// A `cli.Context` writing to memory, for calling `runWith` directly.
const TestContext = struct {
    arena: std.heap.ArenaAllocator,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    environ: std.process.Environ.Map,
    ctx: cli.Context,

    fn init(t: *TestContext) void {
        t.arena = .init(testing.allocator);
        t.out = .init(testing.allocator);
        t.err = .init(testing.allocator);
        t.environ = .init(testing.allocator);
        t.ctx = .{
            .io = testing.io,
            .gpa = testing.allocator,
            .arena = t.arena.allocator(),
            .environ = &t.environ,
            .out = &t.out.writer,
            .err = &t.err.writer,
            .args = &.{},
            .path = &.{&command},
            .occurrences = &.{},
            .app_name = "snek",
        };
    }

    fn deinit(t: *TestContext) void {
        t.environ.deinit();
        t.err.deinit();
        t.out.deinit();
        t.arena.deinit();
    }
};

test "no release published: a clear message, status 1" {
    var t: TestContext = undefined;
    t.init();
    defer t.deinit();
    var memory: MemoryTransport = .{ .routes = &.{} };
    const result = runWith(&t.ctx, .{ .check = true }, memory.transport(), testOptions(), null);
    try testing.expectError(error.CommandFailed, result);
    const expected = "✗ look up the latest release\nsnek: no release of 93ams/snek found: " ++
        "none is published yet (GitHub answered 404 Not Found)\n";
    try testing.expectEqualStrings(expected, t.err.written());
}

test "up to date" {
    var t: TestContext = undefined;
    t.init();
    defer t.deinit();
    var memory: MemoryTransport = .{ .routes = &.{.{ latest_url, releaseJson("v" ++ version) }} };
    try runWith(&t.ctx, .{}, memory.transport(), testOptions(), null);
    try testing.expectEqualStrings("snek " ++ version ++ " is up to date\n", t.out.written());
}

test "--check reports a newer release and downloads nothing" {
    var t: TestContext = undefined;
    t.init();
    defer t.deinit();
    var memory: MemoryTransport = .{ .routes = &.{.{ latest_url, releaseJson("v99.0.0") }} };
    t.ctx.log_level = .debug; // As -v -v sets it.
    try runWith(&t.ctx, .{ .check = true }, memory.transport(), testOptions(), null);
    try testing.expectEqualStrings(
        "snek 99.0.0 is available (this is " ++ version ++ ")\n",
        t.out.written(),
    );
    try testing.expectEqual(1, memory.requests);
    try testing.expectEqualStrings("snek: debug: GET " ++ latest_url ++ "\n" ++
        "✓ look up the latest release\n" ++
        "snek: info: latest release v99.0.0: " ++ asset_name ++ ", checksum in SHA256SUMS, " ++
        "signature none\n", t.err.written());
}

test "--yes downloads, verifies, and installs" {
    var t: TestContext = undefined;
    t.init();
    defer t.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const archive = try testArchive(t.ctx.arena);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    const sums = std.fmt.bytesToHex(digest, .lower) ++ "  " ++ asset_name ++ "\n";
    const routes = [_][2][]const u8{
        .{ latest_url, releaseJson("v99.0.0") },
        .{ "https://dl/" ++ asset_name, archive },
        .{ "https://dl/SHA256SUMS", sums },
    };
    var memory: MemoryTransport = .{ .routes = &routes };
    const destination: Destination = .{ .dir = tmp.dir, .path = "snek" };
    t.ctx.yes = true;
    try runWith(&t.ctx, .{}, memory.transport(), testOptions(), destination);
    try testing.expectEqualStrings(
        "snek 99.0.0 is available (this is " ++ version ++ ")\nupdated snek to snek 99.0.0\n",
        t.out.written(),
    );
    try testing.expectEqualStrings("✓ look up the latest release\n✓ download " ++ asset_name ++
        "\n✓ verify the checksum\n✓ install\n", t.err.written());
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(new_binary, try tmp.dir.readFile(testing.io, "snek", &buffer));
}

test "a corrupted download is not installed" {
    var t: TestContext = undefined;
    t.init();
    defer t.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const zeros: [64]u8 = @splat('0');
    const sums = zeros ++ "  " ++ asset_name ++ "\n";
    const routes = [_][2][]const u8{
        .{ latest_url, releaseJson("v99.0.0") },
        .{ "https://dl/" ++ asset_name, new_binary },
        .{ "https://dl/SHA256SUMS", sums },
    };
    var memory: MemoryTransport = .{ .routes = &routes };
    const destination: Destination = .{ .dir = tmp.dir, .path = "snek" };
    const options = testOptions();
    t.ctx.yes = true;
    const result = runWith(&t.ctx, .{}, memory.transport(), options, destination);
    try testing.expectError(error.CommandFailed, result);
    try testing.expectEqualStrings("✓ look up the latest release\n✓ download " ++ asset_name ++
        "\n✗ verify the checksum\nsnek: " ++ asset_name ++
        " does not match its checksum; not installed\n", t.err.written());
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "snek", .{}));
}

test "the release key is a valid Ed25519 public key" {
    _ = try std.crypto.sign.Ed25519.PublicKey.fromBytes(defaultOptions().public_key.?);
}
