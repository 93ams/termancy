//! Golden files: output checked against a file kept with the tests, and the file rewritten
//! instead when asked (`SNEK_UPDATE_GOLDEN=1 zig build test`). Escape sequences are written
//! out as text (`\x1b[1m`), so golden files of styled output read and diff as text.
//!
//! ```zig
//! test "help" {
//!     try term.golden.expect(std.testing.io, "testdata/help.golden", output, .{});
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const diff = @import("diff.zig");

/// The variable that makes `expect` rewrite golden files instead of comparing.
pub const update_variable = "SNEK_UPDATE_GOLDEN";

/// How `expect` compares.
pub const Options = struct {
    /// Rewrite the file; when null, as `SNEK_UPDATE_GOLDEN` says (in tests).
    update: ?bool = null,
    /// Write control characters out as text (`\x1b`); off, the bytes as they are.
    escape: bool = true,
};

/// What `expect` fails with.
pub const Error = error{GoldenMismatch} || Allocator.Error || Io.Cancelable;

/// Compares `actual` with the golden file at `path` (relative to the working directory),
/// or rewrites it when updating. A missing file is a mismatch that says how to make it.
/// On a mismatch, the lines that differ are printed (to standard error).
pub fn expect(io: Io, path: []const u8, actual: []const u8, options: Options) Error!void {
    const gpa = std.heap.page_allocator;
    const text = if (options.escape) try escape(gpa, actual) else try gpa.dupe(u8, actual);
    defer gpa.free(text);
    const update = options.update orelse updateRequested();
    const cwd = Io.Dir.cwd();
    if (update) {
        if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch {};
        cwd.writeFile(io, .{ .sub_path = path, .data = text }) catch |err| {
            std.debug.print("golden: cannot write {s}: {s}\n", .{ path, @errorName(err) });
            return error.GoldenMismatch;
        };
        return;
    }
    const expected = cwd.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            std.debug.print("golden: cannot read {s} ({s}); run with {s}=1 to write it\n", .{
                path, @errorName(err), update_variable,
            });
            return error.GoldenMismatch;
        },
    };
    defer gpa.free(expected);
    if (std.mem.eql(u8, expected, text)) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    _ = diff.unified(arena.allocator(), &out.writer, path, expected, "actual", text, .{
        .context = 2,
    }) catch return error.OutOfMemory;
    std.debug.print("golden: {s} differs ({s}=1 updates it):\n{s}", .{
        path, update_variable, out.written(),
    });
    return error.GoldenMismatch;
}

fn updateRequested() bool {
    if (!builtin.is_test) return false;
    return std.testing.environ.containsUnempty(
        std.heap.page_allocator,
        update_variable,
    ) catch false;
}

/// `bytes` with control characters (but newlines and tabs) and backslashes written out:
/// `\x1b`, `\r`, `\\`.
pub fn escape(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (bytes) |c| switch (c) {
        '\n', '\t' => out.writer.writeByte(c) catch return error.OutOfMemory,
        '\r' => out.writer.writeAll("\\r") catch return error.OutOfMemory,
        '\\' => out.writer.writeAll("\\\\") catch return error.OutOfMemory,
        0...8, 11...12, 14...31, 127 => out.writer.print(
            "\\x{x:0>2}",
            .{c},
        ) catch return error.OutOfMemory,
        else => out.writer.writeByte(c) catch return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

const testing = std.testing;

test "escape" {
    const got = try escape(testing.allocator, "\x1b[1mhi\x1b[0m\\\r\n\x07");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\\x1b[1mhi\\x1b[0m\\\\\\r\n\\x07", got);
}

test "write, match, mismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/out.golden",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(path);
    try testing.expectError(
        error.GoldenMismatch,
        expect(testing.io, path, "x", .{ .update = false }),
    );
    try expect(testing.io, path, "a\n\x1b[1mb\x1b[0m\nc\n", .{ .update = true });
    try expect(testing.io, path, "a\n\x1b[1mb\x1b[0m\nc\n", .{ .update = false });
    const stored = try tmp.dir.readFileAlloc(
        testing.io,
        "out.golden",
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(stored);
    try testing.expectEqualStrings("a\n\\x1b[1mb\\x1b[0m\nc\n", stored);
}
