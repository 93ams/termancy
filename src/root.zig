//! The application module root, and the executable's entry point.
//!
//! This file sits at `src/root.zig` rather than under `app/` for one measured reason: a Zig
//! module root may only import files **inside the module's path**, and the application needs
//! to reach `src/lib` as well as `src/app`. With the root here, both are inside the module
//! and `main.zig` can name the library it uses; with the root at `src/app/main.zig`, every
//! `@import("../lib/...")` is rejected with `import of file outside module path`. See
//! `SPEC.md` for the probe that established this.
//!
//! `pub fn main` lives here because the executable's root source file *is* the file the
//! entry point is taken from. The body is deliberately one call: `app/main.zig` holds the
//! boot sequence, and everything below that is in `app/cmd` or in a `src/lib` module.

const std = @import("std");

const app = @import("app/main.zig");

/// The application's surface - the `App` alias and the command set - re-exported so a
/// consumer of this module (a test, or a tool added later) reaches it without knowing the
/// folder layout.
pub const App = app.App;
/// The per-invocation state type.
pub const State = app.State;

pub fn main(init: std.process.Init) !void {
    // Delegation, not indirection for its own sake: the entry point has to be in the root
    // source file, and the boot sequence belongs with the app. One call, and the reason is
    // in the header above.
    try app.main(init);
}

test {
    std.testing.refAllDecls(app);
}
