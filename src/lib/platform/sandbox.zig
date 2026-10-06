//! Path-allowance policy for generated code.
//!
//! This file **is** the type: the file's own scope is `Sandbox`, so a consumer
//! writes `const Sandbox = @import("sandbox.zig");`. See the file-layout rule in
//! `.agents/AGENTS.md`.
//!
//! `SandboxPolicy` stays a declaration inside, because it is the sandbox's
//! configuration - one subject.
//!
//! **One recorded defect remains, and it is a decision rather than a bug.**
//! (The sibling-prefix defect that used to head this list is fixed - see
//! `isPathAllowed`.)
//!
//!   * An empty path list means "unrestricted", so the default policy allows
//!     everything. A security default should probably fail closed, but that is a
//!     behaviour change for every existing caller and needs an owner's decision,
//!     so it is recorded here rather than changed.
//!
//! `allow_network` is declared and read by nothing, which is why it is documented
//! as aspirational rather than enforced.
//!
//! **Not handled here, and worth knowing:** this is textual containment over the
//! path as given. It does not normalise, so `..` segments and symlinks are not
//! resolved - a caller that hands untrusted text to `isPathAllowed` still needs to
//! canonicalise it first.

const std = @import("std");

const Self = @This();

pub const separators = "/\\";

/// What a sandbox permits. An empty list means unrestricted - see the module header.
pub const SandboxPolicy = struct {
    read_paths: []const []const u8 = &.{},
    write_paths: []const []const u8 = &.{},
    /// Not enforced anywhere yet.
    allow_network: bool = false,
};

policy: SandboxPolicy,

pub fn init(policy: SandboxPolicy) Self {
    return .{ .policy = policy };
}

/// Whether `target_path` is permitted, for reading or for writing.
///
/// **Containment, not a prefix match.** `startsWith` alone allowed `/data` to permit
/// `/database`, because the byte after the allowed prefix was not a path boundary - a
/// sibling directory whose name merely begins with an allowed one. The rule now is that
/// an allowance covers its own subtree: the target must either *be* the allowed path, or
/// continue past it at a separator.
///
/// An allowance that ends in a separator is the root of a subtree, so `"/"` permits
/// everything and `"/data/"` permits what `"/data"` permits. An allowance *without* a
/// trailing separator also covers its own subtree (`"/data"` permits `"/data/x"`). Both
/// spellings are therefore safe to write, and the sibling exclusion holds for each: the
/// tests assert both rather than leaving it to inference.
///
/// Both separators are recognised so the same policy behaves identically on Windows and
/// POSIX - a path is not rejected merely for being spelled the other way.
pub fn isPathAllowed(self: Self, target_path: []const u8, for_write: bool) bool {
    const paths = if (for_write) self.policy.write_paths else self.policy.read_paths;
    if (paths.len == 0) return true; // Unrestricted if not specified

    for (paths) |allowed| {
        if (std.mem.startsWith(u8, target_path, allowed)) {
            const rest = target_path[allowed.len..];
            // Containment is settled by one question: is the byte after the allowance the
            // end of the target, or a separator? `rest == ""` means the target *is* the
            // allowance (`/data`), and a leading separator means it is inside (`/data/x`).
            // Anything else is a sibling that merely shares the prefix - `/database`,
            // `/data-backup` - and is not covered.
            //
            // A trailing separator on the allowance works out without a special case for
            // `/data/` itself, but an allowance that *is* a separator is the root and covers
            // everything below it: `"/"` against `"/anything"` leaves `rest == "anything"`,
            // whose first byte is not a separator, so the checks below would reject it.
            if (allowed.len > 0 and
                std.mem.indexOfScalar(u8, separators, allowed[allowed.len - 1]) != null)
            {
                return true;
            }
            if (rest.len == 0) return true;
            if (std.mem.indexOfScalar(u8, separators, rest[0]) != null) return true;
        }
    }
    return false;
}

test "an empty policy is unrestricted, which is defect 2" {
    const sb = Self.init(.{});
    try std.testing.expect(sb.isPathAllowed("/anything", false));
    try std.testing.expect(sb.isPathAllowed("/anything", true));
}

test "a listed prefix is allowed and an unlisted path is not" {
    const sb = Self.init(.{
        .read_paths = &.{"/data"},
        .write_paths = &.{"/tmp"},
    });

    try std.testing.expect(sb.isPathAllowed("/data/file", false));
    try std.testing.expect(!sb.isPathAllowed("/other/file", false));
    try std.testing.expect(sb.isPathAllowed("/tmp/x", true));
    // Read and write lists are independent.
    try std.testing.expect(!sb.isPathAllowed("/data/file", true));
}

test "a sibling with the same prefix is NOT permitted - the fixed defect 1" {
    const sb = Self.init(.{ .read_paths = &.{"/data"} });
    // The regression this pins: `startsWith` alone permitted `/database`, because the
    // byte after `/data` was not a boundary. Containment is a path-component rule.
    try std.testing.expect(!sb.isPathAllowed("/database", false));
    try std.testing.expect(!sb.isPathAllowed("/data-backup", false));
    try std.testing.expect(!sb.isPathAllowed("/datax/y", false));
    // ...while the subtree it does own is still permitted.
    try std.testing.expect(sb.isPathAllowed("/data", false));
    try std.testing.expect(sb.isPathAllowed("/data/", false));
    try std.testing.expect(sb.isPathAllowed("/data/x", false));
    try std.testing.expect(sb.isPathAllowed("/data/x/y", false));
}

test "a trailing separator on the allowance still covers its subtree" {
    // An allowance ending in a separator is the root of that subtree, so `/data/` and
    // `/data` permit the same things. Writing it either way is therefore safe, which is
    // the property a policy author needs; the sibling exclusion holds regardless.
    const sb = Self.init(.{ .read_paths = &.{"/data/"} });
    try std.testing.expect(sb.isPathAllowed("/data/", false));
    try std.testing.expect(sb.isPathAllowed("/data/file", false));
    try std.testing.expect(sb.isPathAllowed("/data/a/b", false));
    // Still not a prefix rule: the sibling is excluded in both spellings.
    try std.testing.expect(!sb.isPathAllowed("/database", false));

    const plain = Self.init(.{ .read_paths = &.{"/data"} });
    try std.testing.expect(plain.isPathAllowed("/data/file", false));
    try std.testing.expect(plain.isPathAllowed("/data/", false));
    try std.testing.expect(!plain.isPathAllowed("/database", false));
}

test "the root allowance permits everything, and both separators are recognised" {
    const root = Self.init(.{ .read_paths = &.{"/"} });
    try std.testing.expect(root.isPathAllowed("/anything", false));
    try std.testing.expect(root.isPathAllowed("/", false));

    // A Windows-spelled target against a Windows-spelled allowance: the boundary check
    // must not reject it just because it spells the separator the other way.
    const win = Self.init(.{ .read_paths = &.{"C:\\data"} });
    try std.testing.expect(win.isPathAllowed("C:\\data\\file", false));
    try std.testing.expect(!win.isPathAllowed("C:\\database", false));
    try std.testing.expect(win.isPathAllowed("C:\\data/file", false));

    // And a relative allowance, which is how the integration test uses it.
    const rel = Self.init(.{ .write_paths = &.{"./data/output"} });
    try std.testing.expect(rel.isPathAllowed("./data/output/res.csv", true));
    try std.testing.expect(!rel.isPathAllowed("./data/output2/res.csv", true));
}
