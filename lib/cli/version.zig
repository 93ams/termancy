const std = @import("std");

pub const Config = struct {
    app_name: []const u8,
    current_version: []const u8,
    check_url: []const u8,
    interval_ms: i64 = 24 * 60 * 60 * 1000, // 24 hours
};

/// Spawns a background thread to check for updates if the cache is stale.
/// This will not block the main CLI thread. If the CLI exits before the check completes,
/// the OS will naturally clean up the thread and it will try again next time.
pub fn check(allocator: std.mem.Allocator, config: Config, io: std.Io) void {
    const thread = std.Thread.spawn(.{}, backgroundTask, .{ allocator, config, io }) catch return;
    thread.detach();
}

/// Reads the local cache file and prints an update notice if a newer version is found.
/// This should be called right before the CLI exits (e.g., using defer).
pub fn notifyIfUpdateAvailable(allocator: std.mem.Allocator, config: Config, io: std.Io) !void {
    const cache_path = getCachePath(allocator, config.app_name) catch return;
    defer allocator.free(cache_path);

    const latest = readCache(allocator, cache_path, io) catch return;
    defer allocator.free(latest);

    // Simple string comparison for now. A robust implementation would use semver parsing.
    if (!std.mem.eql(u8, config.current_version, latest)) {
        std.debug.print("\n\x1b[33mUpdate available: {s} -> {s}\x1b[0m\n", .{ config.current_version, latest });
    }
}

fn backgroundTask(allocator: std.mem.Allocator, config: Config, io: std.Io) void {
    const cache_path = getCachePath(allocator, config.app_name) catch return;
    defer allocator.free(cache_path);

    if (isCacheFresh(cache_path, config.interval_ms, io)) return;

    const latest = fetchLatestVersion(allocator, config.check_url) catch return;
    defer allocator.free(latest);

    writeCache(cache_path, latest, io) catch return;
}

fn getCachePath(allocator: std.mem.Allocator, app_name: []const u8) ![]u8 {
    // Store in OS temp dir for simplicity, though ~/.local/share or AppData is better for prod.
    return std.fmt.allocPrint(allocator, "{s}/{s}_version_cache.txt", .{ "/tmp", app_name });
}

fn isCacheFresh(cache_path: []const u8, interval_ms: i64, io: std.Io) bool {
    const stat = std.Io.Dir.cwd().statFile(io, cache_path) catch return false;
    const now = std.time.milliTimestamp();
    const mod_time = @as(i64, @intCast(stat.mtime / 1000000));

    return (now - mod_time) < interval_ms;
}

fn fetchLatestVersion(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var headers = std.ArrayList(u8).init(allocator);
    defer headers.deinit();

    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &headers,
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpError;
    }

    var body = std.ArrayList(u8).init(allocator);
    try req.reader().readAllArrayList(&body, 1024);

    // Trim whitespace and newlines from the fetched version string
    const owned = try body.toOwnedSlice();
    defer allocator.free(owned);
    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn writeCache(cache_path: []const u8, version: []const u8, io: std.Io) !void {
    const file = try std.Io.Dir.cwd().createFile(io, cache_path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, version, 0);
}

fn readCache(allocator: std.mem.Allocator, cache_path: []const u8, io: std.Io) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, cache_path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    const buffers = [_][]u8{&buffer};
    const bytes_read = try file.readStreaming(io, &buffers);
    const trimmed = std.mem.trim(u8, buffer[0..bytes_read], " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}
