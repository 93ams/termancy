const std = @import("std");

pub const MutationType = enum {
    create_file,
    delete_file,
    write_file,
    network_request,
};

pub const MutationRecord = struct {
    action: MutationType,
    target: []const u8,
    details: []const u8 = "",
};

pub const DryRunLedger = struct {
    mutations: std.ArrayList(MutationRecord),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DryRunLedger {
        return .{
            .mutations = std.ArrayList(MutationRecord).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DryRunLedger) void {
        for (self.mutations.items) |m| {
            self.allocator.free(m.target);
            if (m.details.len > 0) self.allocator.free(m.details);
        }
        self.mutations.deinit(self.allocator);
    }

    /// Records one proposed mutation.
    ///
    /// Both strings are copied, and both copies are released if the *second* one fails or
    /// the append does: without the `errdefer`s below, an out-of-memory during the details
    /// copy leaked the target, and a failed append leaked both. `checkAllAllocationFailures`
    /// in the tests fails every allocation in turn to prove it does not.
    pub fn record(self: *DryRunLedger, action: MutationType, target: []const u8, details: []const u8) !void {
        const t = try self.allocator.dupe(u8, target);
        errdefer self.allocator.free(t);

        const d = if (details.len > 0) try self.allocator.dupe(u8, details) else "";
        errdefer if (d.len > 0) self.allocator.free(d);

        try self.mutations.append(self.allocator, .{
            .action = action,
            .target = t,
            .details = d,
        });
    }

    /// Renders the ledger as a diff of what *would* have happened.
    ///
    /// `color` is a parameter rather than a lookup because this module is in `lib/util` and
    /// cannot see `lib/cli`'s capability decision - and unconditional escapes are the bug
    /// this signature exists to prevent: piping the ledger through `grep`, `less` or a file
    /// used to fill it with `\x1b[33;1m`. A caller with a terminal passes `ctx.caps().color`.
    pub fn renderDiff(self: DryRunLedger, writer: anytype, color: bool) !void {
        const bold_yellow = if (color) "\x1b[33;1m" else "";
        const reset = if (color) "\x1b[0m" else "";
        try writer.print("\n{s}=== DRY RUN: Proposed Mutations ==={s}\n", .{ bold_yellow, reset });
        for (self.mutations.items) |m| {
            const tag = switch (m.action) {
                .create_file => if (color) "\x1b[32m[+CREATE]\x1b[0m" else "[+CREATE]",
                .delete_file => if (color) "\x1b[31m[-DELETE]\x1b[0m" else "[-DELETE]",
                .write_file => if (color) "\x1b[36m[~MODIFY]\x1b[0m" else "[~MODIFY]",
                .network_request => if (color) "\x1b[35m[NET_REQ]\x1b[0m" else "[NET_REQ]",
            };
            try writer.print("{s} {s}", .{ tag, m.target });
            if (m.details.len > 0) {
                try writer.print(" ({s})", .{m.details});
            }
            try writer.writeAll("\n");
        }
    }
};

const testing = std.testing;

test "the ledger records every mutation kind and renders them without colour" {
    var ledger = DryRunLedger.init(testing.allocator);
    defer ledger.deinit();

    try ledger.record(.create_file, "a.toml", "");
    try ledger.record(.write_file, "b.toml", "3 keys");
    try ledger.record(.delete_file, "c.toml", "");
    try ledger.record(.network_request, "https://example.invalid", "POST");

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try ledger.renderDiff(&writer, false);
    const rendered = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, rendered, "[+CREATE] a.toml") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "[~MODIFY] b.toml (3 keys)") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "[-DELETE] c.toml") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "[NET_REQ] https://example.invalid (POST)") != null);
    // The whole point of the parameter: no escape codes on a stream that is not a terminal.
    try testing.expect(std.mem.indexOfScalar(u8, rendered, 0x1b) == null);
}

test "colour is per-call, so the same ledger renders either way" {
    var ledger = DryRunLedger.init(testing.allocator);
    defer ledger.deinit();
    try ledger.record(.create_file, "a.toml", "");

    var coloured_buffer: [256]u8 = undefined;
    var coloured = std.Io.Writer.fixed(&coloured_buffer);
    try ledger.renderDiff(&coloured, true);
    try testing.expect(std.mem.indexOfScalar(u8, coloured.buffered(), 0x1b) != null);
    // The reset code sits between the tag and the target, so they are two assertions.
    try testing.expect(std.mem.indexOf(u8, coloured.buffered(), "[+CREATE]") != null);
    try testing.expect(std.mem.indexOf(u8, coloured.buffered(), "a.toml") != null);
}

test "an empty ledger renders a header and nothing else" {
    const ledger = DryRunLedger.init(testing.allocator);
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try ledger.renderDiff(&writer, false);

    const rendered = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, rendered, "=== DRY RUN: Proposed Mutations ===") != null);
    // One header line: no per-mutation output, and no stray blank entry.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, rendered, "\n"));
}

test "a ledger that fails partway through record leaks nothing" {
    // Every allocation in turn is made to fail; `testing.allocator` reports any leak as a
    // test failure, which is what proves the `errdefer`s in `record` are correct rather
    // than merely present.
    try testing.checkAllAllocationFailures(testing.allocator, recordTwoAndDrop, .{});
}

fn recordTwoAndDrop(allocator: std.mem.Allocator) !void {
    var ledger = DryRunLedger.init(allocator);
    defer ledger.deinit();
    try ledger.record(.write_file, "first.toml", "with details");
    try ledger.record(.delete_file, "second.toml", "");
}
