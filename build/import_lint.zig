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

var violations: usize = 0;
var files_scanned: usize = 0;

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

    for (args[1..]) |arg| {
        var dir = std.Io.Dir.cwd().openDir(init.io, arg, .{ .iterate = true }) catch |err| {
            try out.print("import-lint: cannot open {s}: {t}\n", .{ arg, err });
            try out.flush();
            return err;
        };
        defer dir.close(init.io);
        try scanDir(init.io, allocator, dir, arg, out);
    }

    if (violations == 0) {
        try out.print("import-lint: {d} files scanned, no backslash imports\n", .{files_scanned});
        try out.flush();
        return;
    }
    try out.print(
        "import-lint: {d} backslash import(s) in {d} files scanned. Use '/', never '\\'.\n",
        .{ violations, files_scanned },
    );
    try out.flush();
    return error.BackslashImport;
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
