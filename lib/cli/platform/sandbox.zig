//! Path-allowance policy for generated code.
//!
//! This file **is** the type: the file's own scope is `Sandbox`, so a consumer
//! writes `const Sandbox = @import("sandbox.zig");`. See the file-layout rule in
//! `.agents/AGENTS.md`.
//!
//! `SandboxPolicy` stays a declaration inside, because it is the sandbox's
//! configuration - one subject.
//!
//! **Two recorded defects, not fixed here** (`app/cli/lib/ROADMAP.md` section 5.4):
//!
//!   1. `isPathAllowed` matches by *prefix*, so an allowance of `/data` also
//!      permits `/database`. Containment needs a path-component check.
//!   2. An empty path list means "unrestricted", so the default policy allows
//!      everything. A security default should fail closed.
//!
//! `allow_network` is declared and read by nothing, which is why it is documented
//! as aspirational rather than enforced.

const std = @import("std");

const Self = @This();

/// What a sandbox permits. An empty list means unrestricted - see defect 2.
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
/// See defect 1 in the module header: this is a prefix match, not containment.
pub fn isPathAllowed(self: Self, target_path: []const u8, for_write: bool) bool {
    const paths = if (for_write) self.policy.write_paths else self.policy.read_paths;
    if (paths.len == 0) return true; // Unrestricted if not specified

    for (paths) |allowed| {
        if (std.mem.startsWith(u8, target_path, allowed)) {
            return true;
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

test "prefix matching also permits a sibling with the same prefix, which is defect 1" {
    const sb = Self.init(.{ .read_paths = &.{"/data"} });
    // Documented as wrong, and asserted so a fix has to change this test.
    try std.testing.expect(sb.isPathAllowed("/database", false));
}
