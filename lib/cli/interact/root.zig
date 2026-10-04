//! `app/cli/lib/interact` - reading the user.
//!
//! Widgets, text buffers, raw mode, the TTY handle, crash-time terminal restore
//! and the prompt helpers. This is the half of the framework that consumes
//! input; `render/` is the half that produces output.
//!
//! `app/cli/lib/cli.zig` re-exports each of these under its historical flat name
//! (`cli.prompt`, `cli.widgets`, ...).

const std = @import("std");

/// Interactive prompts built on `render/tea`: confirm, select, multi-select.
pub const prompt = @import("prompt.zig");
/// A line editor with echo suppression, for text and password entry.
pub const text_input = @import("text_input.zig");
/// Raw (uncooked) terminal mode, Windows and POSIX.
pub const raw_terminal = @import("raw_terminal.zig");
/// A line buffer for multi-line text editing.
pub const rope = @import("rope.zig");
/// The sane-terminal sequence to emit after a crash.
pub const supervisor = @import("supervisor.zig");
/// Resolving and opening the controlling TTY, as opposed to stdio.
pub const tty_stream = @import("tty_stream.zig");
/// Focus management, clipboard (OSC 52), fuzzy finding, hotkey overlays and
/// forms.
pub const widgets = @import("widgets.zig");

test {
    // Shallow by design; every namespace is named. See `app/cli/lib/ROADMAP.md` M-2.
    std.testing.refAllDecls(prompt);
    std.testing.refAllDecls(text_input);
    std.testing.refAllDecls(raw_terminal);
    std.testing.refAllDecls(rope);
    std.testing.refAllDecls(supervisor);
    std.testing.refAllDecls(tty_stream);
    std.testing.refAllDecls(widgets);
}
