//! `interact` - interactive terminal input.
//!
//! Prompts, text entry, raw-terminal handling, widgets and the supervisor that restores a sane terminal after a crash. This is the module that reads stdin, and the only one that does.
//!
//! This file is the module's public surface. `lib.zig` is the folder's own
//! re-export list, and its declarations are inherited below so that a consumer writes
//! `interact.thing` rather than `interact.lib.thing` - which is how this folder was reached
//! before the module split.

const std = @import("std");

/// The folder's own re-exports.
pub const lib = @import("lib.zig");
pub const prompt = lib.prompt;
pub const text_input = lib.text_input;
pub const raw_terminal = lib.raw_terminal;
pub const rope = lib.rope;
pub const supervisor = lib.supervisor;
pub const tty_stream = lib.tty_stream;
pub const widgets = lib.widgets;

test {
    // Shallow by design: a `test` block is collected only when a declaration in the
    // namespace references it, so lib is named here and lib.zig names each of its own
    // sub-modules. A subdirectory missing from that list loses its tests silently
    // rather than failing the build - see ROADMAP.md M-2.
    std.testing.refAllDecls(lib);
}
