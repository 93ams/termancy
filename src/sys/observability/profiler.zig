//! A phase timer: named, nested phases on a monotonic clock, reported as a text table or JSON.
//!
//! ```zig
//! var prof: profiler.Profiler(build_options.profile) = .init(gpa, .{ .io = io });
//! defer prof.deinit();
//! try prof.begin("load");
//! try prof.begin("parse");
//! prof.end("parse");
//! prof.end("load");
//! try prof.writeText(stderr);
//! ```
//!
//! `Profiler(false)` stores nothing and every method is empty, so instrumentation can stay
//! in release builds at no cost. Phase names are borrowed and must outlive the profiler.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Where readings come from.
pub const Clock = union(enum) {
    /// The monotonic (`awake`) clock of this `Io`.
    io: Io,
    /// Reads whatever the pointee holds; for tests.
    manual: *const Io.Timestamp,

    /// The current reading.
    pub fn now(clock: Clock) Io.Timestamp {
        return switch (clock) {
            .io => |io| Io.Clock.awake.now(io),
            .manual => |instant| instant.*,
        };
    }
};

/// One finished or running phase.
pub const Phase = struct {
    name: []const u8,
    /// 0 for top-level phases.
    depth: u32,
    /// Since the profiler was created.
    start_ns: u64,
    /// Null while running.
    duration_ns: ?u64 = null,
};

/// A profiler that records when `enabled` and compiles to nothing otherwise.
pub fn Profiler(comptime enabled: bool) type {
    return if (enabled) Recording else Disabled;
}

/// The disabled profiler: the same interface, no state, no work.
pub const Disabled = struct {
    /// Creates the profiler; the arguments are ignored.
    pub fn init(gpa: Allocator, clock: Clock) Disabled {
        _ = gpa;
        _ = clock;
        return .{};
    }

    /// Does nothing.
    pub fn deinit(_: *Disabled) void {}

    /// Does nothing.
    pub inline fn begin(_: *Disabled, name: []const u8) Allocator.Error!void {
        _ = name;
    }

    /// Does nothing.
    pub inline fn end(_: *Disabled, name: []const u8) void {
        _ = name;
    }

    /// Always empty.
    pub fn phases(_: *const Disabled) []const Phase {
        return &.{};
    }

    /// Writes nothing.
    pub fn writeText(_: *const Disabled, w: *Io.Writer) Io.Writer.Error!void {
        _ = w;
    }

    /// Writes nothing.
    pub fn writeJson(_: *const Disabled, w: *Io.Writer) Io.Writer.Error!void {
        _ = w;
    }
};

/// The recording profiler.
pub const Recording = struct {
    gpa: Allocator,
    clock: Clock,
    origin: Io.Timestamp,
    list: std.ArrayList(Phase) = .empty,
    /// Indices into `list` of the running phases, outermost first.
    open: std.ArrayList(u32) = .empty,

    /// Creates the profiler; its time origin is now.
    pub fn init(gpa: Allocator, clock: Clock) Recording {
        return .{ .gpa = gpa, .clock = clock, .origin = clock.now() };
    }

    /// Frees the recorded phases.
    pub fn deinit(prof: *Recording) void {
        prof.list.deinit(prof.gpa);
        prof.open.deinit(prof.gpa);
        prof.* = undefined;
    }

    /// Starts `name`, nested inside the phase currently running, if any.
    pub fn begin(prof: *Recording, name: []const u8) Allocator.Error!void {
        try prof.list.ensureUnusedCapacity(prof.gpa, 1);
        try prof.open.ensureUnusedCapacity(prof.gpa, 1);
        const index: u32 = @intCast(prof.list.items.len);
        prof.list.appendAssumeCapacity(.{
            .name = name,
            .depth = @intCast(prof.open.items.len),
            .start_ns = prof.elapsed(),
        });
        prof.open.appendAssumeCapacity(index);
    }

    /// Ends the innermost running phase, which must be `name`.
    pub fn end(prof: *Recording, name: []const u8) void {
        const index = prof.open.pop() orelse unreachable; // `end` without `begin`.
        const phase = &prof.list.items[index];
        assert(std.mem.eql(u8, phase.name, name));
        phase.duration_ns = prof.elapsed() - phase.start_ns;
    }

    /// Every phase in start order.
    pub fn phases(prof: *const Recording) []const Phase {
        return prof.list.items;
    }

    /// Sum of the top-level phases. Every phase must have ended.
    pub fn totalNs(prof: *const Recording) u64 {
        assert(prof.open.items.len == 0);
        var total: u64 = 0;
        for (prof.list.items) |phase| {
            if (phase.depth == 0) total += phase.duration_ns.?;
        }
        return total;
    }

    /// A table: phase (indented by depth), milliseconds, share of the total.
    ///
    /// ```text
    /// phase            ms       %
    /// load         12.000    80.0
    ///   parse       3.000    20.0
    /// total        15.000   100.0
    /// ```
    pub fn writeText(prof: *const Recording, w: *Io.Writer) Io.Writer.Error!void {
        const total = prof.totalNs();
        var width: usize = "total".len;
        for (prof.list.items) |phase| width = @max(width, 2 * phase.depth + phase.name.len);
        try w.writeAll("phase");
        try w.splatByteAll(' ', width - "phase".len);
        try w.writeAll("          ms       %\n");
        for (prof.list.items) |phase| {
            try w.splatByteAll(' ', 2 * phase.depth);
            try w.writeAll(phase.name);
            try w.splatByteAll(' ', width - 2 * phase.depth - phase.name.len);
            try writeRow(w, phase.duration_ns.?, total);
        }
        try w.writeAll("total");
        try w.splatByteAll(' ', width - "total".len);
        try writeRow(w, total, total);
    }

    /// `{"total_ns":N,"phases":[{"name":"load","depth":0,"start_ns":0,"duration_ns":N}]}`
    pub fn writeJson(prof: *const Recording, w: *Io.Writer) Io.Writer.Error!void {
        var json: std.json.Stringify = .{ .writer = w };
        try json.beginObject();
        try json.objectField("total_ns");
        try json.write(prof.totalNs());
        try json.objectField("phases");
        try json.write(prof.list.items);
        try json.endObject();
        try w.writeByte('\n');
    }

    fn elapsed(prof: *const Recording) u64 {
        const ns = prof.origin.durationTo(prof.clock.now()).nanoseconds;
        assert(ns >= 0); // The clock is monotonic.
        return @intCast(ns);
    }
};

fn writeRow(w: *Io.Writer, ns: u64, total: u64) Io.Writer.Error!void {
    const ms_whole = ns / std.time.ns_per_ms;
    const ms_frac = ns % std.time.ns_per_ms / std.time.ns_per_us;
    // Tenths of a percent, in integers so output does not depend on float formatting.
    const permille: u64 = if (total == 0) 0 else @intCast(@as(u128, ns) * 1000 / total);
    try w.print(" {d:>7}.{d:0>3} {d:>5}.{d}\n", .{
        ms_whole, ms_frac, permille / 10, permille % 10,
    });
}

const testing = std.testing;

fn ms(n: u64) i96 {
    return n * std.time.ns_per_ms;
}

test "nested phases with a manual clock" {
    var now: Io.Timestamp = .fromNanoseconds(ms(1000));
    var prof: Profiler(true) = .init(testing.allocator, .{ .manual = &now });
    defer prof.deinit();
    try prof.begin("load");
    now = .fromNanoseconds(ms(1002));
    try prof.begin("parse");
    now = .fromNanoseconds(ms(1005) + 250_000);
    prof.end("parse");
    now = .fromNanoseconds(ms(1012));
    prof.end("load");
    try prof.begin("run");
    now = .fromNanoseconds(ms(1015));
    prof.end("run");

    const phases = prof.phases();
    try testing.expectEqual(3, phases.len);
    try testing.expectEqualStrings("parse", phases[1].name);
    try testing.expectEqual(1, phases[1].depth);
    try testing.expectEqual(2_000_000, phases[1].start_ns);
    try testing.expectEqual(3_250_000, phases[1].duration_ns);
    try testing.expectEqual(15_000_000, prof.totalNs());

    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try prof.writeText(&w);
    try testing.expectEqualStrings(
        \\phase            ms       %
        \\load         12.000    80.0
        \\  parse       3.250    21.6
        \\run           3.000    20.0
        \\total        15.000   100.0
        \\
    , w.buffered());

    w = .fixed(&buffer);
    try prof.writeJson(&w);
    try testing.expectEqualStrings(
        "{\"total_ns\":15000000,\"phases\":[" ++
            "{\"name\":\"load\",\"depth\":0,\"start_ns\":0,\"duration_ns\":12000000}," ++
            "{\"name\":\"parse\",\"depth\":1,\"start_ns\":2000000,\"duration_ns\":3250000}," ++
            "{\"name\":\"run\",\"depth\":0,\"start_ns\":12000000,\"duration_ns\":3000000}]}\n",
        w.buffered(),
    );
}

test "an empty profile reports a zero total" {
    var now: Io.Timestamp = .zero;
    var prof: Profiler(true) = .init(testing.allocator, .{ .manual = &now });
    defer prof.deinit();
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try prof.writeText(&w);
    try testing.expectEqualStrings(
        "phase          ms       %\ntotal       0.000     0.0\n",
        w.buffered(),
    );
}

test "the disabled profiler records nothing and has no state" {
    try testing.expectEqual(0, @sizeOf(Profiler(false)));
    var prof: Profiler(false) = .init(testing.allocator, .{ .io = testing.io });
    defer prof.deinit();
    try prof.begin("load");
    prof.end("load");
    try testing.expectEqual(0, prof.phases().len);
    var buffer: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try prof.writeText(&w);
    try prof.writeJson(&w);
    try testing.expectEqual(0, w.buffered().len);
}

test "the real clock is monotonic" {
    var prof: Profiler(true) = .init(testing.allocator, .{ .io = testing.io });
    defer prof.deinit();
    try prof.begin("a");
    prof.end("a");
    try testing.expect(prof.phases()[0].duration_ns != null);
}

test "allocation failure leaves the profiler consistent" {
    var now: Io.Timestamp = .zero;
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    var prof: Profiler(true) = .init(failing.allocator(), .{ .manual = &now });
    defer prof.deinit();
    try testing.expectError(error.OutOfMemory, prof.begin("a"));
    try testing.expectEqual(0, prof.open.items.len);
}
