//! `app/cli/lib/render` - turning data into terminal bytes.
//!
//! Styling, colour, tables, layout, graphics, progress, paging, a screen model
//! and the escape-sequence emitters. Nothing here reads input or touches process
//! state; everything writes to a caller-supplied writer.
//!
//! `app/cli/lib/cli.zig` re-exports each of these under its historical flat name
//! (`cli.style`, `cli.tea`, ...), so this file is the directory's own surface
//! rather than a new one. Keeping it means the folder has an entry point like
//! every other folder in the repository, and it is where a folder-level test
//! root would live.

const std = @import("std");

/// Escape-sequence construction for DECSTBM scroll regions.
pub const decstbm = @import("decstbm.zig");
/// The single process-wide decision about whether escapes may be emitted.
pub const capability = @import("capability.zig");
/// Truecolor/256/16-colour degradation and terminal profile detection.
pub const color = @import("color.zig");
/// Inline images: kitty, iTerm2 and sixel protocol detection and encoding.
pub const graphics = @import("graphics.zig");
/// Split-pane composition.
pub const layout = @import("layout.zig");
/// Paging long output through the user's pager.
pub const pager = @import("pager.zig");
/// Single and multi progress bars.
pub const progress = @import("progress.zig");
/// A 2-D focus grid for spatial navigation.
pub const spatial_focus = @import("spatial_focus.zig");
/// Styling, borders, hyperlinks, aligned text and tables.
pub const style = @import("style.zig");
/// A single-line spinner for a step whose total is unknown.
pub const spinner = @import("spinner.zig");
/// The Elm-style event loop (`Program`, `Msg`, `Channel`).
pub const tea = @import("tea.zig");
/// A width/height cell grid with an SVG exporter.
pub const virtual_terminal = @import("virtual_terminal.zig");
/// Escape-sequence *emitters* and OSC replies: sync output, taskbar progress,
/// bracketed paste, adaptive palette queries.
pub const vte = @import("vte.zig");

test {
    // `refAllDecls` is shallow: it reaches the declarations of the
    // namespaces named here, and a `test` block is collected only when a
    // declaration in that namespace references it. Each one is therefore
    // listed explicitly. See `app/cli/lib/ROADMAP.md` M-2.
    std.testing.refAllDecls(decstbm);
    std.testing.refAllDecls(capability);
    std.testing.refAllDecls(color);
    std.testing.refAllDecls(graphics);
    std.testing.refAllDecls(layout);
    std.testing.refAllDecls(pager);
    std.testing.refAllDecls(progress);
    std.testing.refAllDecls(spatial_focus);
    std.testing.refAllDecls(style);
    std.testing.refAllDecls(spinner);
    std.testing.refAllDecls(tea);
    std.testing.refAllDecls(virtual_terminal);
    std.testing.refAllDecls(vte);
}
