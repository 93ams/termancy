//! The cross-module behavioural suite.
//!
//! `cli_test.zig` exercises routing, flags, help, completion, the render layer, the prompts
//! and the secret handling in one place, because the behaviours it pins are about how those
//! fit together rather than about any one of them. It therefore cannot live inside a single
//! `src/lib/<module>` - it would make that module depend on the other five. It lives here,
//! beside the app, and this file is the root the build points its test artifact at.
//!
//! `ROADMAP.md` RISK-LAYOUT-2 records why this file exists rather than the suite being
//! scattered: it is the safety net for the whole module split, and scattering it would have
//! made "did the split lose a test?" unanswerable at a glance.

const std = @import("std");

const suite = @import("cli_test.zig");

test {
    std.testing.refAllDecls(suite);
}
