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

/// A model for the `tea.Program` tests, at file scope because a type declared inside a test
/// that is itself inside a generic exhausts the compiler's memory - see `tea.zig`'s note.
/// It quits on `q`, which is all the four `Program` tests need to terminate.
pub const RenderTestModel = struct {
    seen: u8 = 0,
    quit: bool = false,

    pub fn update(self: *@This(), msg: tea.Msg(void)) !tea.Command(void) {
        switch (msg) {
            .key => |k| {
                self.seen = k.char orelse 0;
                if (k.key == .char and k.char == 'q') self.quit = true;
            },
            else => {},
        }
        return if (self.quit) .quit else .none;
    }

    pub fn view(self: *@This(), writer: *std.Io.Writer) !void {
        try writer.writeAll(if (self.quit) "done\n" else "working\n");
    }
};

test {
    // Shallow by design: a `test` block is collected only when a declaration in the
    // namespace references it, so `lib` is named here and `lib.zig` names each of its own
    // sub-modules. A subdirectory missing from that list loses its tests silently rather
    // than failing the build - see `ROADMAP.md` M-2.
    std.testing.refAllDecls(lib);

    // The four `Program` tests live inside `tea.Program`, which is a *generic*: they are
    // collected only when some instantiation is referenced. Referencing one here is what
    // makes them run in this module's own test artifact.
    //
    // This line is load-bearing, and it is the migration's one measured coverage loss:
    // before the split the old single root reached `Program` through
    // `interact.prompt.confirm`'s model as well, so eight of these ran; `render` cannot
    // name `interact` (that edge would be a cycle), so exactly one instantiation runs here
    // and the other is covered by `src/test/cli_test.zig`, which can see both modules.
    std.testing.refAllDecls(tea.Program(RenderTestModel, void));
}
