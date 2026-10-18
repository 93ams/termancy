//! `zig build bench`: how fast `cfg` parses, writes, merges, and decodes, on documents
//! generated with a fixed shape so that every run measures the same work. Built with
//! ReleaseFast; not part of `zig build test`, since timings depend on the machine.
//!
//! Each line is one benchmark: its name, the best time of several runs, and the
//! throughput for the parsers. Compare runs on one machine to see a regression.

const std = @import("std");
const cfg = @import("cfg");
const Io = std.Io;

/// Runs of each benchmark; the fastest counts, which filters out interference.
const runs = 7;

const Settings = struct {
    servers: []const Server = &.{},
    name: []const u8 = "",
    debug: bool = false,

    const Server = struct {
        host: []const u8 = "",
        port: u16 = 0,
        tags: []const []const u8 = &.{},
        weight: f64 = 0,
    };
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try document(arena, 5_000);

    try out.print("{s:<28} {s:>12} {s:>10}\n", .{ "benchmark", "best", "MB/s" });
    for ([_]cfg.Format{ .json, .toml, .yaml, .zon, .ini }) |format| {
        var text: Io.Writer.Allocating = .init(arena);
        const value = if (format == .ini) try stringsOnly(arena, tree) else tree;
        format.write(&text.writer, value) catch |err| switch (err) {
            error.Unrepresentable => continue,
            else => |e| return e,
        };
        const source = text.written();
        const parse_ns = try best(io, gpa, ParseBench{ .format = format, .source = source });
        try report(out, "parse", format, parse_ns, source.len);
        const write_ns = try best(io, gpa, WriteBench{ .format = format, .tree = tree });
        try report(out, "write", format, write_ns, source.len);
    }
    var time_buffer: [32]u8 = undefined;
    const merge_ns = try best(io, gpa, MergeBench{ .tree = tree });
    try out.print("{s:<28} {s:>12}\n", .{ "merge (5 layers)", duration(&time_buffer, merge_ns) });
    const decode_ns = try best(io, gpa, DecodeBench{ .tree = tree });
    try out.print("{s:<28} {s:>12}\n", .{ "decode (struct)", duration(&time_buffer, decode_ns) });
    try out.flush();
}

fn report(out: *Io.Writer, what: []const u8, format: cfg.Format, ns: u64, bytes: usize) !void {
    var name_buffer: [32]u8 = undefined;
    const kib = bytes / 1024;
    const name = try std.fmt.bufPrint(&name_buffer, "{s} {t} ({d} KiB)", .{ what, format, kib });
    const seconds = @as(f64, @floatFromInt(@max(ns, 1))) / 1e9;
    const mb_per_s = @as(f64, @floatFromInt(bytes)) / 1e6 / seconds;
    var time_buffer: [32]u8 = undefined;
    const time = duration(&time_buffer, ns);
    try out.print("{s:<28} {s:>12} {d:>10.1}\n", .{ name, time, mb_per_s });
}

/// `ns` in the largest unit that keeps four digits or more.
fn duration(buffer: []u8, ns: u64) []const u8 {
    const result = if (ns < 10_000)
        std.fmt.bufPrint(buffer, "{d} ns", .{ns})
    else if (ns < 10_000_000)
        std.fmt.bufPrint(buffer, "{d} us", .{ns / 1000})
    else
        std.fmt.bufPrint(buffer, "{d} ms", .{ns / 1_000_000});
    return result catch "?";
}

/// The fastest of `runs` runs of `bench.run`, each with a fresh arena.
fn best(io: Io, gpa: std.mem.Allocator, bench: anytype) !u64 {
    var fastest: u64 = std.math.maxInt(u64);
    for (0..runs) |_| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const start: Io.Timestamp = .now(io, .awake);
        try bench.run(arena.allocator());
        const elapsed = start.untilNow(io, .awake).toNanoseconds();
        fastest = @min(fastest, @as(u64, @intCast(@max(elapsed, 0))));
    }
    return fastest;
}

const ParseBench = struct {
    format: cfg.Format,
    source: []const u8,
    fn run(b: ParseBench, arena: std.mem.Allocator) !void {
        _ = try b.format.parse(arena, b.source, null);
    }
};

const WriteBench = struct {
    format: cfg.Format,
    tree: cfg.Value,
    fn run(b: WriteBench, arena: std.mem.Allocator) !void {
        var out: Io.Writer.Allocating = .init(arena);
        const value = if (b.format == .ini) try stringsOnly(arena, b.tree) else b.tree;
        try b.format.write(&out.writer, value);
    }
};

const MergeBench = struct {
    tree: cfg.Value,
    fn run(b: MergeBench, arena: std.mem.Allocator) !void {
        var result: cfg.Value = .empty_table;
        for (0..5) |_| try result.merge(arena, b.tree);
    }
};

const DecodeBench = struct {
    tree: cfg.Value,
    fn run(b: DecodeBench, arena: std.mem.Allocator) !void {
        _ = try cfg.decode(Settings, arena, b.tree, .{}, null);
    }
};

/// A configuration with `count` servers, each a table of scalars and a list.
fn document(arena: std.mem.Allocator, count: usize) !cfg.Value {
    var root: cfg.Value = .empty_table;
    try root.put(arena, "name", .{ .string = "benchmark" });
    try root.put(arena, "debug", .{ .bool = true });
    var servers: cfg.Array = .empty;
    for (0..count) |i| {
        var server: cfg.Value = .empty_table;
        const host = try std.fmt.allocPrint(arena, "host-{d}.example.com", .{i});
        try server.put(arena, "host", .{ .string = host });
        try server.put(arena, "port", .{ .int = @intCast(1024 + i % 60000) });
        try server.put(arena, "weight", .{ .float = @as(f64, @floatFromInt(i)) / 7.0 });
        var tags: cfg.Array = .empty;
        for (0..3) |t| {
            try tags.append(arena, .{ .string = try std.fmt.allocPrint(arena, "tag{d}", .{t}) });
        }
        try server.put(arena, "tags", .{ .array = tags });
        try servers.append(arena, server);
    }
    try root.put(arena, "servers", .{ .array = servers });
    return root;
}

/// INI holds no arrays of tables: the servers become one section each.
fn stringsOnly(arena: std.mem.Allocator, tree: cfg.Value) !cfg.Value {
    var root: cfg.Value = .empty_table;
    for (tree.lookup("servers").?.array.items, 0..) |server, i| {
        const key = try std.fmt.allocPrint(arena, "server{d}", .{i});
        try root.put(arena, key, server);
    }
    return root;
}
