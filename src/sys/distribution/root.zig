//! `sys/distribution` - getting a program to its users and keeping it current:
//! semantic versions, self-update from GitHub releases, package-manager manifests, and
//! files fetched from a URL with a cache (remote configuration).
//!
//! Nothing here touches the network or the filesystem unless the caller calls a function
//! that says it does (`update.apply`, `update.install`, `update.HttpTransport.fetch`).

const std = @import("std");

/// Semantic version parse, format, and precedence (SemVer 2.0.0).
pub const Version = @import("version.zig");
/// Self-update: release lookup, checksum and signature verification, atomic install.
pub const update = @import("update.zig");
/// Homebrew, Scoop, PKGBUILD, and Debian control files from one package description.
pub const manifests = @import("manifests.zig");
/// A URL's body, revalidated with its ETag, and read from a cache when offline.
pub const remote = @import("remote.zig");

test {
    // `refAllDecls` is shallow, so every file is named here; a file missing from this list
    // would have its tests silently skipped.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Version);
    std.testing.refAllDecls(update);
    std.testing.refAllDecls(manifests);
    std.testing.refAllDecls(remote);
}
