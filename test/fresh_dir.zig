//! `fresh_dir <file>`: empties the directory `file` is in, then writes `file` (empty). The first
//! step of an end-to-end chain, run in the chain's directory: the build system never empties a
//! directory it reuses, and a restored build cache (as CI's) can hold one an unfinished run
//! left files in, while the record that the chain finished is gone.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return error.Usage;
    const file = args[1];
    var dir = try Io.Dir.cwd().openDir(io, std.fs.path.dirname(file) orelse ".", .{ .iterate = true });
    defer dir.close(io);
    // Names first: deleting while iterating may skip entries.
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| try names.append(arena, try arena.dupe(u8, entry.name));
    for (names.items) |name| try dir.deleteTree(io, name);
    try dir.writeFile(io, .{ .sub_path = std.fs.path.basename(file), .data = "" });
}
