//! OpenSSH's `known_hosts`: which host keys belong to which hosts. Lines are
//! `[@revoked] patterns keytype base64 [comment]`; patterns are host names, `[host]:port`
//! for ports other than 22, wildcards (`*`, `?`), negations (`!pattern`), or one hashed
//! name (`|1|salt|hmac`, as `HashKnownHosts` writes). `@cert-authority` lines are skipped
//! (certificates are not supported).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const keys = @import("keys.zig");
const known_hosts = @This();
const base64 = std.base64.standard;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

pub const Match = enum {
    /// A line gives this key for the host.
    known,
    /// No line names the host.
    unknown,
    /// Lines name the host, with other keys: the key changed, or someone is in between.
    changed,
    /// The key is marked `@revoked`.
    revoked,
};

/// What `text` (a `known_hosts` file) says of `key` for `host` on `port`.
pub fn check(text: []const u8, host: []const u8, port: u16, key: keys.PublicKey) Match {
    var name_buffer: [300]u8 = undefined;
    const name = hostName(&name_buffer, host, port) orelse return .unknown;
    var result: Match = .unknown;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const entry = parse(line) orelse continue;
        if (!hostsMatch(entry.patterns, name)) continue;
        const same = std.mem.eql(u8, entry.kind, key.algorithm()) and
            blobIs(entry.data, key.blob);
        if (entry.revoked) {
            if (same) return .revoked;
        } else if (same) {
            result = .known;
        } else if (result == .unknown) result = .changed;
    }
    return result;
}

/// The key types `text` holds for `host` on `port` (as host key algorithms, the
/// preferred first), then the rest of `all`, in `out`: offering the known kinds first keeps
/// a server with several keys from showing one not on file.
pub fn algorithms(
    text: []const u8,
    host: []const u8,
    port: u16,
    all: []const []const u8,
    out: [][]const u8,
) [][]const u8 {
    var name_buffer: [300]u8 = undefined;
    var n: usize = 0;
    if (hostName(&name_buffer, host, port)) |name| {
        for (all) |algorithm| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                const entry = parse(line) orelse continue;
                if (entry.revoked or !hostsMatch(entry.patterns, name)) continue;
                if (!std.mem.eql(u8, entry.kind, keyType(algorithm))) continue;
                out[n] = algorithm;
                n += 1;
                break;
            }
        }
    }
    for (all) |algorithm| {
        for (out[0..n]) |taken| {
            if (std.mem.eql(u8, taken, algorithm)) break;
        } else {
            out[n] = algorithm;
            n += 1;
        }
    }
    return out[0..n];
}

/// The key type a host key algorithm signs with.
fn keyType(algorithm: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, algorithm, "rsa-sha2-")) "ssh-rsa" else algorithm;
}

/// Writes the line that records `key` for `host` on `port` (with its newline).
pub fn writeLine(w: *Io.Writer, host: []const u8, port: u16, key: keys.PublicKey) !void {
    var name_buffer: [300]u8 = undefined;
    const name = hostName(&name_buffer, host, port) orelse return error.NameTooLong;
    try w.print("{s} ", .{name});
    try key.writeLine(w, "");
    try w.writeByte('\n');
}

const Entry = struct {
    revoked: bool,
    patterns: []const u8,
    kind: []const u8,
    data: []const u8,
};

fn parse(raw: []const u8) ?Entry {
    const line = std.mem.trim(u8, raw, " \t\r\n");
    if (line.len == 0 or line[0] == '#') return null;
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    var first = fields.next() orelse return null;
    var revoked = false;
    if (first[0] == '@') {
        if (!std.mem.eql(u8, first, "@revoked")) return null;
        revoked = true;
        first = fields.next() orelse return null;
    }
    return .{
        .revoked = revoked,
        .patterns = first,
        .kind = fields.next() orelse return null,
        .data = fields.next() orelse return null,
    };
}

/// `host` as `known_hosts` names it: lowercase, and `[host]:port` unless the port is 22.
fn hostName(buffer: *[300]u8, host: []const u8, port: u16) ?[]const u8 {
    const name = (if (port == 22)
        std.fmt.bufPrint(buffer, "{s}", .{host})
    else
        std.fmt.bufPrint(buffer, "[{s}]:{d}", .{ host, port })) catch return null;
    return std.ascii.lowerString(name, name);
}

fn blobIs(data: []const u8, blob: []const u8) bool {
    var buffer: [2048]u8 = undefined;
    const size = base64.Decoder.calcSizeForSlice(data) catch return false;
    if (size != blob.len or size > buffer.len) return false;
    base64.Decoder.decode(buffer[0..size], data) catch return false;
    return std.mem.eql(u8, buffer[0..size], blob);
}

/// Whether the comma-separated `patterns` take `name`: one matches and no negated one
/// does.
fn hostsMatch(patterns: []const u8, name: []const u8) bool {
    if (std.mem.startsWith(u8, patterns, "|1|")) return hashedMatch(patterns[3..], name);
    var matched = false;
    var it = std.mem.splitScalar(u8, patterns, ',');
    while (it.next()) |pattern| {
        if (pattern.len > 0 and pattern[0] == '!') {
            if (glob(pattern[1..], name)) return false;
        } else if (glob(pattern, name)) matched = true;
    }
    return matched;
}

/// `salt|hmac`, both base64: HMAC-SHA1 of the name under the salt.
fn hashedMatch(field: []const u8, name: []const u8) bool {
    const bar = std.mem.indexOfScalar(u8, field, '|') orelse return false;
    var salt: [HmacSha1.key_length]u8 = undefined;
    var expected: [HmacSha1.mac_length]u8 = undefined;
    const salt_text = field[0..bar];
    const mac_text = field[bar + 1 ..];
    if ((base64.Decoder.calcSizeForSlice(salt_text) catch return false) != salt.len) return false;
    if ((base64.Decoder.calcSizeForSlice(mac_text) catch return false) != expected.len)
        return false;
    base64.Decoder.decode(&salt, salt_text) catch return false;
    base64.Decoder.decode(&expected, mac_text) catch return false;
    var mac: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&mac, name, &salt);
    return std.crypto.timing_safe.eql([HmacSha1.mac_length]u8, mac, expected);
}

/// `*` and `?` wildcards, ASCII case ignored.
fn glob(pattern: []const u8, name: []const u8) bool {
    if (pattern.len == 0) return name.len == 0;
    if (pattern[0] == '*') {
        for (0..name.len + 1) |i| if (glob(pattern[1..], name[i..])) return true;
        return false;
    }
    if (name.len == 0) return false;
    if (pattern[0] != '?' and std.ascii.toLower(pattern[0]) != name[0]) return false;
    return glob(pattern[1..], name[1..]);
}

/// A host key check against a `known_hosts` file, for `Client.Config.verify_host_key`
/// (with the verifier as the context).
pub const Verifier = struct {
    gpa: Allocator,
    io: Io,
    /// The file (relative to the working directory, or absolute).
    path: []const u8,
    host: []const u8,
    port: u16 = 22,
    policy: Policy = .strict,
    /// What the file said, once checked (for messages).
    found: Match = .unknown,
    /// Set when a new key was recorded.
    added: bool = false,
    /// The fingerprint of the key checked (for messages).
    fingerprint: []const u8 = "",
    fingerprint_buffer: [50]u8 = undefined,

    pub const Policy = enum {
        /// Only keys on file pass.
        strict,
        /// A host not on file passes and is recorded; a changed key never passes.
        accept_new,
    };

    pub fn check(context: ?*anyopaque, key: keys.PublicKey) bool {
        const v: *Verifier = @ptrCast(@alignCast(context.?));
        v.fingerprint = key.fingerprint(&v.fingerprint_buffer);
        const text = v.read() catch return false;
        defer v.gpa.free(text);
        v.found = known_hosts.check(text, v.host, v.port, key);
        switch (v.found) {
            .known => return true,
            .changed, .revoked => return false,
            .unknown => {
                if (v.policy != .accept_new) return false;
                v.append(key) catch return false;
                v.added = true;
                return true;
            },
        }
    }

    /// The file's text (empty when there is no file).
    pub fn read(v: *const Verifier) ![]u8 {
        return Io.Dir.cwd().readFileAlloc(v.io, v.path, v.gpa, .limited(16 << 20)) catch |err|
            switch (err) {
                error.FileNotFound => try v.gpa.alloc(u8, 0),
                else => |e| e,
            };
    }

    fn append(v: *const Verifier, key: keys.PublicKey) !void {
        var buffer: [1200]u8 = undefined;
        var w: Io.Writer = .fixed(&buffer);
        try writeLine(&w, v.host, v.port, key);
        const cwd = Io.Dir.cwd();
        if (std.fs.path.dirname(v.path)) |dir| try cwd.createDirPath(v.io, dir);
        const file = try cwd.createFile(v.io, v.path, .{ .truncate = false });
        defer file.close(v.io);
        const end = try file.length(v.io);
        try file.writePositionalAll(v.io, w.buffered(), end);
    }
};

const testing = std.testing;

test "known, unknown, changed, revoked; ports, wildcards, negation" {
    const a_blob = (keys.KeyPair.fromSeed(@splat(1))).publicBlob();
    const b_blob = (keys.KeyPair.fromSeed(@splat(2))).publicBlob();
    const c_blob = (keys.KeyPair.fromSeed(@splat(3))).publicBlob();
    const ka = try keys.PublicKey.parse(&a_blob);
    const kb = try keys.PublicKey.parse(&b_blob);
    const kc = try keys.PublicKey.parse(&c_blob);
    var buffer: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.writeAll("# comment\n\n");
    try writeLine(&w, "example.com", 22, ka);
    try writeLine(&w, "Example.com", 2222, kb);
    try w.writeAll("*.lan,!bad.lan ");
    try ka.writeLine(&w, "a comment");
    try w.writeAll("\n@revoked * ");
    try kb.writeLine(&w, "");
    try w.writeAll("\n@cert-authority *.ca ");
    try ka.writeLine(&w, "");
    try w.writeByte('\n');
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "[example.com]:2222 ssh-ed25519 ") != null);
    try testing.expectEqual(.known, check(text, "EXAMPLE.com", 22, ka));
    try testing.expectEqual(.changed, check(text, "example.com", 22, kc));
    try testing.expectEqual(.revoked, check(text, "example.com", 2222, kb));
    try testing.expectEqual(.changed, check(text, "example.com", 2222, kc));
    try testing.expectEqual(.unknown, check(text, "example.org", 22, ka));
    try testing.expectEqual(.known, check(text, "printer.lan", 22, ka));
    try testing.expectEqual(.unknown, check(text, "bad.lan", 22, ka));
    try testing.expectEqual(.unknown, check(text, "x.ca", 22, ka));
}

test "hashed names, as ssh-keygen -H writes them" {
    // `|1|` + base64(salt) + `|` + base64(HMAC-SHA1(salt, "[localhost]:2222")).
    const salt: [20]u8 = @splat(7);
    var mac: [20]u8 = undefined;
    HmacSha1.create(&mac, "[localhost]:2222", &salt);
    var salt_text: [28]u8 = undefined;
    var mac_text: [28]u8 = undefined;
    const kp: keys.KeyPair = .fromSeed(@splat(3));
    const blob = kp.publicBlob();
    const key = try keys.PublicKey.parse(&blob);
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("|1|{s}|{s} ", .{
        base64.Encoder.encode(&salt_text, &salt),
        base64.Encoder.encode(&mac_text, &mac),
    });
    try key.writeLine(&w, "");
    try testing.expectEqual(.known, check(w.buffered(), "localhost", 2222, key));
    try testing.expectEqual(.unknown, check(w.buffered(), "localhost", 22, key));
    // A line OpenSSH 10's ssh-keygen -H wrote for [localhost]:2222.
    const theirs =
        "|1|lo5QFFugFU1HuklJ758Gj+QhPiQ=|ajbkt5dgCaUf5qpL5B/8HOuVlgE= ssh-ed25519 " ++
        "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n";
    const entry = parse(theirs).?;
    var their_blob: [51]u8 = undefined;
    try base64.Decoder.decode(&their_blob, entry.data);
    const their_key = try keys.PublicKey.parse(&their_blob);
    try testing.expectEqual(.known, check(theirs, "localhost", 2222, their_key));
    try testing.expectEqual(.changed, check(theirs, "localhost", 2222, key));
    try testing.expectEqual(.unknown, check(theirs, "localhost", 2223, key));
}

test algorithms {
    const kp: keys.KeyPair = .fromSeed(@splat(4));
    const blob = kp.publicBlob();
    const key = try keys.PublicKey.parse(&blob);
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.writeAll("host ssh-rsa AAAA\n");
    try writeLine(&w, "other", 22, key);
    var out: [8][]const u8 = undefined;
    const all = [_][]const u8{ "ssh-ed25519", "rsa-sha2-512", "rsa-sha2-256" };
    const got = algorithms(w.buffered(), "host", 22, &all, &out);
    try testing.expectEqualStrings("rsa-sha2-512", got[0]);
    try testing.expectEqualStrings("rsa-sha2-256", got[1]);
    try testing.expectEqualStrings("ssh-ed25519", got[2]);
}
