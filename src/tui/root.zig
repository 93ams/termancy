//! `tui` - terminal user interfaces: an Elm-architecture program runner, key bindings,
//! focus, and headless testing, on top of `term` (terminal control, styles, layout, input
//! events), whose names are re-exported here so a program needs one import. Ready-made
//! components are not here: they are source files an application copies and owns
//! (`termancy tui add <component>`), each built on this module.
//!
//! | name | |
//! |---|---|
//! | `Program(Model)`, `Msg`, `Message(App)`, `Cmd`, `Options`, `Outcome` | the runner |
//! | `run`, `runSession`, `RunOptions` | in one call: on the terminal (a snapshot without one), or remote |
//! | `Keymap`, `keymap` | key bindings declared once, matched in `update`, listed as help |
//! | `focus` | focus rings and grids for moving between components |
//! | `motion` | `Spring` and `Projectile`: physics for animations, as harmonica |
//! | `testing` | `Driver(Model)`: a program over memory with a virtual clock and screen |
//! | `term`, and its `Terminal`, `Style`, `Color`, `layout`, `width`, `input`, ... | see `term` |
//!
//! A component is a model: a struct with `update` and `view`, usable on its own as a
//! program and embeddable in a larger model by forwarding messages to it.
//!
//! ```zig
//! const std = @import("std");
//! const tui = @import("tui");
//!
//! pub const Confirm = struct {
//!     question: []const u8,
//!     answer: bool = false,
//!
//!     pub fn update(model: *Confirm, msg: tui.Msg) tui.Cmd {
//!         const key = switch (msg) {
//!             .key => |key| key,
//!             else => return .none,
//!         };
//!         if (key.matches("y")) model.answer = true;
//!         if (key.matches("n")) model.answer = false;
//!         if (key.matches("enter") or key.matches("y") or key.matches("n")) return .quit;
//!         return .none;
//!     }
//!
//!     pub fn view(model: *const Confirm, w: *std.Io.Writer) std.Io.Writer.Error!void {
//!         const accent: tui.Style = .{ .fg = .hex(0xff8700), .bold = true };
//!         try accent.paint(w, "? ");
//!         try w.print("{s} [y/N]\n", .{model.question});
//!     }
//! };
//!
//! test Confirm {
//!     var driver: tui.testing.Driver(Confirm) = try .init(std.testing.allocator, .{
//!         .question = "Continue?",
//!     }, .{});
//!     defer driver.deinit();
//!     try driver.expectFrame("? Continue? [y/N]");
//!     try driver.press("y");
//!     try std.testing.expect(driver.done() and driver.model().answer);
//! }
//! ```
//!
//! Running it for real: `run` opens the terminal, detects its colors, runs the program,
//! and returns the exit status (130 after Ctrl-C). Without a terminal it prints the first
//! frame as text to `snapshot_out` instead, or fails when that is null.
//!
//! ```zig
//! var confirm: Confirm = .{ .question = "Continue?" };
//! const status = try tui.run(gpa, io, &confirm, .{ .environ = environ });
//! if (status != 0) return status;
//! if (confirm.answer) ...
//! ```
//!
//! The model stays the caller's: `Program` updates it in place through a pointer and never
//! frees it (`testing.Driver`, which takes a model by value, owns and frees its own).
//! `Program(Model).init` and `Program.run` are the same steps by hand, for a terminal of
//! your own.
//!
//! Conventions: everything writes to a `*std.Io.Writer`; nothing allocates except where an
//! `Allocator` is passed (`Program`, `input.Decoder`, `testing`); no threads or timers run
//! inside the module: `Program.run` waits on input with a deadline through `std.Io`, and
//! the core it drives is plain function calls. Views write colors at full fidelity;
//! `Program` lowers them to the terminal's capability. The one global is
//! `Terminal.restoreOnPanic`'s record of the raw-mode terminal.
//!
//! The module imports `std` and `term`.

const std = @import("std");

const program = @import("Program.zig");

pub const Program = program.Program;
pub const Message = program.Message;
pub const Msg = program.Msg;
pub const Cmd = program.Cmd;
pub const Options = program.Options;
pub const Outcome = program.Outcome;
pub const rowsOf = program.rowsOf;

const run_zig = @import("run.zig");
pub const run = run_zig.run;
pub const runSession = run_zig.runSession;
pub const RunOptions = run_zig.RunOptions;
pub const interrupted_status = run_zig.interrupted_status;

pub const term = @import("term");
pub const Terminal = term.Terminal;
pub const Size = term.Size;
pub const Style = term.Style;
pub const Color = term.Color;
pub const ansi = term.ansi;
pub const capability = term.capability;
pub const input = term.input;
pub const layout = term.layout;
pub const width = term.width;

pub const keymap = @import("keymap.zig");
pub const focus = @import("focus.zig");
pub const motion = @import("motion.zig");
pub const Cursor = program.Cursor;
pub const Keymap = keymap.Keymap;
pub const testing = @import("testing.zig");

test {
    // `refAllDecls` is shallow, so every file is named here; a file missing from this list
    // would have its tests silently skipped.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(program);
    std.testing.refAllDecls(run_zig);
    std.testing.refAllDecls(keymap);
    std.testing.refAllDecls(focus);
    std.testing.refAllDecls(motion);
    std.testing.refAllDecls(testing);
}

test "the example component in the header" {
    const tui = @This();
    const Confirm = struct {
        question: []const u8,
        answer: bool = false,

        pub fn update(model: *@This(), msg: tui.Msg) tui.Cmd {
            const key = switch (msg) {
                .key => |key| key,
                else => return .none,
            };
            if (key.matches("y")) model.answer = true;
            if (key.matches("n")) model.answer = false;
            if (key.matches("enter") or key.matches("y") or key.matches("n")) return .quit;
            return .none;
        }

        pub fn view(model: *const @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            const accent: tui.Style = .{ .fg = .hex(0xff8700), .bold = true };
            try accent.paint(w, "? ");
            try w.print("{s} [y/N]\n", .{model.question});
        }
    };
    var driver: tui.testing.Driver(Confirm) = try .init(std.testing.allocator, .{
        .question = "Continue?",
    }, .{});
    defer driver.deinit();
    try driver.expectFrame("? Continue? [y/N]");
    try driver.press("y");
    try std.testing.expect(driver.done() and driver.model().answer);
}
