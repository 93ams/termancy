//! `app/cli/lib/test` - the framework's test suite.
//!
//! One file, 91 tests, covering the framework and every sub-module. It lives in
//! its own folder rather than beside `cli.zig` because the implementation file
//! is already 1,900 lines and the suite is another 2,300.
//!
//! **This file exists because a module root must reach the suite.** A `test`
//! block is collected only when a declaration in the compiled root's namespace
//! references it, and `refAllDecls` is shallow, so the suite must be named
//! explicitly by whoever wants it to run. Today that is `app/cli/lib/root.zig`:
//!
//! ```zig
//! const suite = @import("test/cli_test.zig");
//! test { std.testing.refAllDecls(suite); }
//! ```
//!
//! Adding a second entry point here is a mistake unless it also names the
//! suite. See `app/cli/lib/ROADMAP.md` M-2 for the measured rule and the control
//! experiment behind it.

const std = @import("std");

/// The suite. Importing this file does not run its tests; see the note above.
pub const cli_test = @import("cli_test.zig");

test {
    std.testing.refAllDecls(cli_test);
}
