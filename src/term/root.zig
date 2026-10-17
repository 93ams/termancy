//! `term` - the terminal underneath `cli` and `tui`: what it can show, how wide text is,
//! escape sequences both ways, styled text and its layout, and the terminal device itself.
//! Everything here writes to a `*std.Io.Writer` or reads bytes; nothing runs an event loop
//! (that is `tui.Program`).
//!
//! | name | |
//! |---|---|
//! | `capability` | `detect(environ, .{ .is_tty })`: color level and whether escapes are allowed; `ci` |
//! | `width` | display width (`of`), `truncate`, `wrap`, `Wrapper`, cluster `Iterator` |
//! | `ansi` | escape sequences as functions; `strip`, `downsample`; `Color` |
//! | `Style`, `Color` | colors and attributes; padding, margin, border, width, alignment |
//! | `layout` | `joinHorizontal`, `joinVertical`, `place`, `size`, `split` |
//! | `input` | `Key` (`parse`, `matches`, `printable`), `Mouse`, `Event`, `Decoder`, `encode` |
//! | `Parser` | the VT500 state machine: text and every kind of escape sequence, as actions |
//! | `Pen` | the attributes SGR sets, applied from parameters and written as the shortest change |
//! | `vt` | `Screen`: a virtual terminal that runs what a real one runs, for tests and capture |
//! | `explain` | escape sequences in words (`describe`), and output split into text and sequences |
//! | `Pty` | a program on a pseudo-terminal (ConPTY on Windows): its output, input, size |
//! | `Buffer` | a grid of cells: styled text laid out, blocks drawn over it, rows written out |
//! | `Renderer` | frames to a terminal, writing only the cells that changed |
//! | `Canvas`, `Layer` | blocks at positions, stacked by depth: dialogs, toasts, popups |
//! | `Table` | a table drawn as text: header, rows, borders, cell styles, a width to fit |
//! | `List`, `Tree` | lists (bullets, numbers, letters, roman) and trees drawn as text |
//! | `highlight` | syntax highlighting: 30 languages, themes (charm, dracula, monokai, ...) |
//! | `TrueType` | TrueType fonts: glyphs by codepoint, metrics, anti-aliased masks |
//! | `image` | RGBA images; PNG and GIF written and read; JPEG read (baseline, progressive) |
//! | `graphics` | images in the terminal: kitty, iTerm2, sixel, or half-block mosaic |
//! | `golden` | output checked against golden files, rewritten on `SNEK_UPDATE_GOLDEN=1` |
//! | `diff` | line diffs (Myers): `unified` writes `diff -u` output, colored or plain |
//! | `raster` | a screen drawn as pixels in a font, and the window around it |
//! | `fonts` | the machine's fonts, found by family name, loaded with fallbacks |
//! | `Regex` | regular expressions for waiting on screens and matching lines |
//! | `markdown` | Markdown rendered for the terminal, as glamour: style sheets, highlighting |
//! | `live` | spinners, progress bars, step lists: redrawn in place, or a line per change |
//! | `Terminal`, `Size` | raw mode, size, the controlling terminal, restore on panic |
//!
//! ```zig
//! const term = @import("term");
//!
//! const cap = term.capability.detect(environ, .{ .is_tty = true });
//! const title: term.Style = .{ .fg = .hex(0xff8700), .bold = true };
//! try title.renderFor(w, cap.color, "Hello");
//! ```
//!
//! The module imports only `std`. It builds for WASI too, where `Terminal` finds no
//! terminal.

const std = @import("std");

pub const ansi = @import("ansi.zig");
pub const capability = @import("capability.zig");
pub const width = @import("width.zig");
pub const input = @import("input.zig");
pub const Parser = @import("Parser.zig");
pub const Pen = @import("Pen.zig");
pub const vt = @import("vt.zig");
pub const explain = @import("explain.zig");
pub const Pty = @import("Pty.zig");
pub const graphics = @import("graphics.zig");
pub const golden = @import("golden.zig");
pub const diff = @import("diff.zig");
pub const Buffer = @import("Buffer.zig");
pub const Renderer = @import("Renderer.zig");
pub const Canvas = @import("Canvas.zig");
pub const Layer = Canvas.Layer;
pub const Table = @import("Table.zig");
pub const List = @import("List.zig");
pub const Tree = @import("Tree.zig");
pub const highlight = @import("highlight.zig");
pub const markdown = @import("markdown.zig");
pub const TrueType = @import("TrueType.zig");
pub const image = @import("image.zig");
pub const raster = @import("raster.zig");
pub const fonts = @import("fonts.zig");
pub const Regex = @import("Regex.zig");
pub const layout = @import("layout.zig");
pub const Style = @import("Style.zig");
pub const live = @import("live.zig");
pub const Color = ansi.Color;
pub const Terminal = @import("Terminal.zig");
pub const Size = Terminal.Size;

test {
    // `refAllDecls` is shallow, so every file is named here; a file missing from this list
    // would have its tests silently skipped.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ansi);
    std.testing.refAllDecls(capability);
    std.testing.refAllDecls(width);
    std.testing.refAllDecls(input);
    std.testing.refAllDecls(Parser);
    std.testing.refAllDecls(Pen);
    std.testing.refAllDecls(vt);
    std.testing.refAllDecls(explain);
    std.testing.refAllDecls(Pty);
    std.testing.refAllDecls(Buffer);
    std.testing.refAllDecls(Renderer);
    std.testing.refAllDecls(Canvas);
    std.testing.refAllDecls(Table);
    std.testing.refAllDecls(List);
    std.testing.refAllDecls(Tree);
    std.testing.refAllDecls(highlight);
    std.testing.refAllDecls(markdown);
    std.testing.refAllDecls(TrueType);
    std.testing.refAllDecls(image);
    std.testing.refAllDecls(raster);
    std.testing.refAllDecls(fonts);
    std.testing.refAllDecls(Regex);
    std.testing.refAllDecls(layout);
    std.testing.refAllDecls(Style);
    std.testing.refAllDecls(Terminal);
    std.testing.refAllDecls(graphics);
    std.testing.refAllDecls(golden);
    std.testing.refAllDecls(diff);
    std.testing.refAllDecls(live);
    _ = @import("fuzz.zig");
}
