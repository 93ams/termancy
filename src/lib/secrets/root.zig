//! `secrets` - secret handling.
//!
//! A secret value that does not print itself, a locked heap, and the redaction rules. Kept apart from platform because its consumers are the configuration layer, not the operating system.
//!
//! This file is the module's public surface. `lib.zig` is the folder's own
//! re-export list, and its declarations are inherited below so that a consumer writes
//! `secrets.thing` rather than `secrets.lib.thing` - which is how this folder was reached
//! before the module split.

const std = @import("std");

/// The folder's own re-exports.
pub const lib = @import("lib.zig");
pub usingnamespace lib;

test {
    // Shallow by design: a `test` block is collected only when a declaration in the
    // namespace references it, so lib is named here and lib.zig names each of its own
    // sub-modules. A subdirectory missing from that list loses its tests silently
    // rather than failing the build - see ROADMAP.md M-2.
    std.testing.refAllDecls(lib);
}
