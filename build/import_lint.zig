//! Source lint: `@import` paths use `/`, never a backslash.
//!
//! This exists because the repository has already been bitten once, and by its own tooling:
//! two PowerShell string-replace round-trips rewrote six import paths to use Windows
//! separators, and Zig reads a backslash before a path segment as an invalid escape. The
//! symptom was `expected '{', found 't'` on a line nowhere near the cause, so the failure
//! cost several rounds of looking in the wrong place. A byte this cheap to check should not
//! be checked by eye.
//!
//! `MIGRATION.md` records the incident; this program is what stops it recurring. The
//! offending string is deliberately **not** spelled out above: this file is scanned like
//! any other, so writing an example would make the lint fail on its own documentation. The
//! matcher below is assembled from parts for the same reason - the trick
//! `src/app/lib/ops/root.zig` uses for its own self-scanning guard.
//!
//! It is a `zig build` dependency rather than a unit test because the property is about
//! *source text*, and a test artifact cannot read its own tree portably - the test binary
//! runs somewhere else, and `@embedFile` needs one literal path per file it wants to see.

const std = @import("std");

/// How many offending lines to print before summarising. A file that is entirely mangled
/// should not bury the first useful line.
const max_reported = 20;

/// How many unnamed files to list per module before "and N more".
const max_missing_reported = 8;

var violations: usize = 0;
var files_scanned: usize = 0;
var unnamed: usize = 0;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    // `args[0]` is this program's own path; everything after it is a directory to scan.
    if (args.len < 2) {
        std.debug.print("usage: import-lint <dir>...\n", .{});
        return error.NoInput;
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var scanned_any = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        // `--modules <lib dir>` switches to the second check: every `.zig` file under a module
        // directory must be named by that module's own collector.
        //
        // The directory is a separate token rather than `--modules=<dir>` because the build
        // passes it with `addFileArg`, which appends one argument and has no way to interpolate
        // it into a formatted string.
        if (std.mem.eql(u8, arg, "--modules")) {
            i += 1;
            if (i >= args.len) {
                try out.print("import-lint: --modules needs a directory\n", .{});
                try out.flush();
                return error.NoInput;
            }
            try checkModules(init.io, allocator, args[i], out);
            continue;
        }
        var dir = std.Io.Dir.cwd().openDir(init.io, arg, .{ .iterate = true }) catch |err| {
            try out.print("import-lint: cannot open {s}: {t}\n", .{ arg, err });
            try out.flush();
            return err;
        };
        defer dir.close(init.io);
        scanned_any = true;
        try scanDir(init.io, allocator, dir, arg, out);
    }

    // Each mode reports only its own result: printing "0 files scanned" after a modules-only
    // run reads as though nothing was checked, when 7 modules were.
    if (scanned_any) {
        if (violations == 0) {
            try out.print("import-lint: {d} file(s) scanned, no backslash imports\n", .{files_scanned});
        } else {
            try out.print(
                "import-lint: {d} backslash import(s) in {d} file(s) scanned. Use '/', never '\\'.\n",
                .{ violations, files_scanned },
            );
        }
    }
    if (unnamed != 0) {
        try out.print(
            "import-lint: {d} file(s) are not named by their module's collector, so any tests in them never run. See ROADMAP.md M-2.\n",
            .{unnamed},
        );
    }
    try out.flush();
    if (violations != 0 or unnamed != 0) return error.LintFailed;
}

/// Every `.zig` file in a module directory must appear **by name** in that module's collector
/// (`root.zig`, or `lib.zig` when the root re-exports through one).
///
/// This is the check that makes a silent failure loud. `refAllDecls` is shallow, so a sibling
/// file that no declaration references contributes no tests - the build stays green and the
/// suite simply gets smaller. That is exactly how four `tea.Program` tests were lost during
/// the layout migration, and it is the class `ROADMAP.md` M-2 documents. Naming is the fix;
/// this verifies the naming happened.
///
/// It deliberately does not require a `refAllDecls` call, only the name: `framework/root.zig`
/// legitimately reaches its files through `pub const i18n = framework.i18n`, and a file may
/// hold no tests at all. What it catches is a file nobody mentioned.
fn checkModules(io: std.Io, allocator: std.mem.Allocator, lib_dir: []const u8, out: *std.Io.Writer) !void {
    var modules = std.Io.Dir.cwd().openDir(io, lib_dir, .{ .iterate = true }) catch |err| {
        try out.print("import-lint: cannot open {s}: {t}\n", .{ lib_dir, err });
        return err;
    };
    defer modules.close(io);

    var it = modules.iterate();
    var checked: usize = 0;
    var modules_with_missing: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // Copied out of the iterator: `entry.name` is only valid until the next `next()`, and
        // the second walk below invalidates it. Reporting a stale name printed `root.zigig`
        // in the control experiment - the symptom of reusing that slice.
        const module_name = try allocator.dupe(u8, entry.name);
        const module_path = try std.fs.path.join(allocator, &.{ lib_dir, module_name });
        var dir = modules.openDir(io, module_name, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        // `lib.zig` is the collector when present, otherwise `root.zig` is.
        var collector_name: []const u8 = "root.zig";
        if (dir.access(io, "lib.zig", .{})) |_| {
            collector_name = "lib.zig";
        } else |_| {}

        const collector_text = dir.readFileAlloc(io, collector_name, allocator, .limited(4 * 1024 * 1024)) catch |err| {
            try out.print("import-lint: {s} has no {s}: {t}\n", .{ module_path, collector_name, err });
            unnamed += 1;
            modules_with_missing += 1;
            continue;
        };

        var files = dir.iterate();
        var missing = std.ArrayList([]const u8).empty;
        var total: usize = 0;
        while (try files.next(io)) |file_entry| {
            if (file_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, file_entry.name, ".zig")) continue;
            const name = try allocator.dupe(u8, file_entry.name);
            const base = name[0 .. name.len - ".zig".len];
            // The collector itself is the entry point; `lib` is the other collector.
            if (std.mem.eql(u8, base, "root") or std.mem.eql(u8, base, "lib")) continue;
            total += 1;
            if (std.mem.indexOf(u8, collector_text, base) == null) {
                try missing.append(allocator, name);
            }
        }
        checked += 1;
        if (missing.items.len != 0) {
            unnamed += missing.items.len;
            modules_with_missing += 1;
            try out.print("{s}/{s} does not name {d} of its {d} files:\n", .{
                module_path, collector_name, missing.items.len, total,
            });
            for (missing.items[0..@min(missing.items.len, max_missing_reported)]) |name| {
                try out.print("  {s}\n", .{name});
            }
            if (missing.items.len > max_missing_reported) {
                try out.print("  ... and {d} more\n", .{missing.items.len - max_missing_reported});
            }
        }
    }
    // Guard the guard: a wrong directory would otherwise pass by having nothing to check.
    if (checked == 0) {
        try out.print("import-lint: no module directories under {s}\n", .{lib_dir});
        unnamed += 1;
    } else if (modules_with_missing == 0) {
        try out.print("import-lint: {d} module(s) under {s} named every file\n", .{ checked, lib_dir });
    } else {
        try out.print("import-lint: {d} of {d} module(s) under {s} are incomplete\n", .{
            modules_with_missing, checked, lib_dir,
        });
    }
}

fn scanDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    display_path: []const u8,
    out: *std.Io.Writer,
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ display_path, entry.name });
        switch (entry.kind) {
            .directory => {
                var child = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| {
                    try out.print("import-lint: skipping {s}: {t}\n", .{ child_path, err });
                    continue;
                };
                defer child.close(io);
                try scanDir(io, allocator, child, child_path, out);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const text = dir.readFileAlloc(io, entry.name, allocator, .limited(4 * 1024 * 1024)) catch |err| {
                    try out.print("import-lint: cannot read {s}: {t}\n", .{ child_path, err });
                    continue;
                };
                files_scanned += 1;
                try scanFile(child_path, text, out);
            },
            else => {},
        }
    }
}

fn scanFile(display_path: []const u8, text: []const u8, out: *std.Io.Writer) !void {
    // Assembled from parts so this file can be scanned like any other: a whole literal here
    // would match the very line that documents it. The directory guard in
    // `src/app/lib/ops/root.zig` takes the same precaution for the same reason.
    const opener = "@import(" ++ "\"";
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        line_number += 1;
        const at = std.mem.indexOf(u8, line, opener) orelse continue;
        const rest = line[at + opener.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const path = rest[0..end];
        // A backslash anywhere in the path is the corruption; one that Zig tolerated as an
        // escape would still be a path that does not mean what it looks like.
        if (std.mem.indexOfScalar(u8, path, '\\') == null) continue;

        violations += 1;
        if (violations <= max_reported) {
            try out.print("{s}:{d}: import path uses a backslash: {s}{s}\")\n", .{
                display_path, line_number, opener, path,
            });
        }
    }
}
