//! `render` - turning data into terminal bytes.
//!
//! Styling, colour, tables, layout, graphics, progress, paging, a screen model and the
//! escape-sequence emitters. It reads no input and touches no process state: everything
//! writes to a caller-supplied writer.
//!
//! This file is the module's public surface. `lib.zig` is the folder's own re-export list,
//! and its declarations are inherited below so that a consumer writes `render.tea` rather
//! than `render.lib.tea` - which is how this folder was reached before the module split.

const std = @import("std");

/// The folder's own re-exports.
pub const lib = @import("lib.zig");
pub const decstbm = lib.decstbm;
pub const capability = lib.capability;
pub const color = lib.color;
pub const graphics = lib.graphics;
pub const layout = lib.layout;
pub const pager = lib.pager;
pub const progress = lib.progress;
pub const spatial_focus = lib.spatial_focus;
pub const style = lib.style;
pub const spinner = lib.spinner;
pub const tea = lib.tea;
pub const virtual_terminal = lib.virtual_terminal;
pub const vte = lib.vte;

test {
    // Shallow by design: a `test` block is collected only when a declaration in the
    // namespace references it, so `lib` is named here and `lib.zig` names each of its own
    // sub-modules. A subdirectory missing from that list loses its tests silently rather
    // than failing the build - see `ROADMAP.md` M-2.
    std.testing.refAllDecls(lib);
}
