const std = @import("std");

pub const RemoteProvider = struct {
    name: []const u8,
    url: []const u8,
    timeout_ms: u32 = 5000,
};

pub const CachedRemoteState = struct {
    etag: []const u8 = "",
    payload: []const u8 = "",
    timestamp: i64 = 0,
};

pub const RemoteConfigManager = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RemoteConfigManager {
        return .{ .allocator = allocator };
    }

    /// Read local cached state if available
    pub fn readCache(self: RemoteConfigManager, io: std.Io, cache_path: []const u8) ?CachedRemoteState {
        const file = std.Io.Dir.cwd().openFile(io, cache_path, .{}) catch return null;
        defer file.close(io);

        var buf: [16384]u8 = undefined;
        const bufs = [_][]u8{&buf};
        const n = file.readStreaming(io, &bufs) catch return null;
        if (n == 0) return null;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, buf[0..n], .{}) catch return null;
        defer parsed.deinit();

        if (parsed.value != .object) return null;

        const etag_val = parsed.value.object.get("etag") orelse return null;
        const payload_val = parsed.value.object.get("payload") orelse return null;

        if (etag_val != .string or payload_val != .string) return null;

        const etag_duped = self.allocator.dupe(u8, etag_val.string) catch return null;
        const payload_duped = self.allocator.dupe(u8, payload_val.string) catch {
            self.allocator.free(etag_duped);
            return null;
        };

        return CachedRemoteState{
            .etag = etag_duped,
            .payload = payload_duped,
            .timestamp = std.Io.Clock.now(.real, io).toSeconds(),
        };
    }

    /// Write cached state to disk
    pub fn writeCache(self: RemoteConfigManager, io: std.Io, cache_path: []const u8, etag: []const u8, payload: []const u8) !void {
        _ = self;
        const file = try std.Io.Dir.cwd().createFile(io, cache_path, .{ .truncate = true });
        defer file.close(io);

        const CacheRecord = struct {
            etag: []const u8,
            payload: []const u8,
            timestamp: i64,
        };
        const rec = CacheRecord{
            .etag = etag,
            .payload = payload,
            .timestamp = @intCast(std.Io.Clock.now(.real, io).toSeconds()),
        };

        var json_buf: [16384]u8 = undefined;
        var writer = std.Io.Writer.fixed(&json_buf);
        try std.json.fmt(rec, .{}).format(&writer);

        const bytes = json_buf[0 .. json_buf.len - writer.unusedCapacityLen()];
        try file.writePositionalAll(io, bytes, 0);
    }

    /// Free a cached remote state
    pub fn freeState(self: RemoteConfigManager, state: *CachedRemoteState) void {
        if (state.etag.len > 0) self.allocator.free(state.etag);
        if (state.payload.len > 0) self.allocator.free(state.payload);
        state.* = .{};
    }
};
