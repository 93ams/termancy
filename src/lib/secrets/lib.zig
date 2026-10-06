//! `app/cli/lib/secrets` - handling values that must not leak.
//!
//! Wiping, redaction, locked pages and encryption at rest. Deliberately its own
//! folder rather than part of `platform/`: these are the files where a mistake is
//! a security defect, not a bug, and they are the strongest candidate for moving
//! to a `lib/`-level module once `lib/sec` compiles (see `app/cli/lib/ROADMAP.md`
//! U-0 tier 3 and repo-wide item R-4).
//!
//! `app/cli/lib/cli.zig` re-exports each of these under its historical flat name
//! (`cli.security`, `cli.secret_val`, ...).

const std = @import("std");
const zcfg = @import("cfg");

/// Zeroing and redaction primitives.
pub const security = @import("security.zig");
/// `Secret(T)`: an owned, optionally page-locked value that is wiped on deinit.
pub const secret_val = @import("secret_val.zig");
/// A page-locked allocation. Misnamed: it does not use OS page primitives, see
/// `app/cli/lib/ROADMAP.md` section 5.4.
pub const secure_heap = @import("secure_heap.zig");
/// XChaCha20-Poly1305 encryption at rest for a configuration file.
///
/// Moved to `lib/cfg`, where the rest of the configuration surface lives. It imports only
/// `std`, so the move changed no dependency; re-exported here so `cli.encrypted_config`
/// keeps resolving for existing callers.
pub const encrypted_config = zcfg.encrypted_config;

test {
    // Shallow by design; every namespace is named. See `app/cli/lib/ROADMAP.md` M-2.
    std.testing.refAllDecls(security);
    std.testing.refAllDecls(secret_val);
    std.testing.refAllDecls(secure_heap);
    std.testing.refAllDecls(zcfg.encrypted_config);
}
