//! Writing a recording: a GIF; PNG frames into a directory; the screens as text (golden
//! files for tests); an animated SVG (crisp at any size, small, for READMEs); or MP4 and
//! WebM through ffmpeg when it is installed. And the screenshots a tape took.

const std = @import("std");
const term = @import("term");
const session = @import("session.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Recording = session.Recording;
const Frame = session.Frame;

pub const Error = error{ WriteFailed, Unsupported, Canceled } || Allocator.Error;

pub const Kind = enum { gif, png_frames, png, text, svg, video };

/// What `path`'s extension asks for.
pub fn kindOf(path: []const u8) ?Kind {
    if (std.mem.endsWith(u8, path, "/") or std.mem.endsWith(u8, path, "\\")) return .png_frames;
    const ext = std.fs.path.extension(path);
    const kinds = [_]struct { []const u8, Kind }{
        .{ ".gif", .gif }, .{ ".png", .png },   .{ ".txt", .text },   .{ ".ascii", .text },
        .{ ".svg", .svg }, .{ ".mp4", .video }, .{ ".webm", .video }, .{ ".mov", .video },
    };
    for (kinds) |k| if (std.ascii.eqlIgnoreCase(k[0], ext)) return k[1];
    return null;
}

/// Draws frames: the screen's cells in a font, in the window the config describes.
pub const Drawing = struct {
    gpa: Allocator,
    painter: *term.raster.Painter,
    screen: term.vt.Screen,
    config: *const session.Config,
    title_font: ?*const term.TrueType,

    pub fn init(
        gpa: Allocator,
        painter: *term.raster.Painter,
        recording: *const Recording,
        title_font: ?*const term.TrueType,
    ) Allocator.Error!Drawing {
        var screen: term.vt.Screen = try .init(gpa, recording.size);
        recording.config.theme.apply(&screen);
        return .{
            .gpa = gpa,
            .painter = painter,
            .screen = screen,
            .config = &recording.config,
            .title_font = title_font,
        };
    }

    pub fn deinit(d: *Drawing) void {
        d.screen.deinit();
    }

    /// The frame as an image (the caller frees it); the cursor shown when `cursor`.
    pub fn draw(d: *Drawing, frame: *const Frame, cursor: bool) Allocator.Error!term.image.Image {
        @memcpy(d.screen.grid().cells, frame.cells);
        d.screen.row = frame.row;
        d.screen.column = frame.column;
        d.screen.cursor_visible = cursor and frame.cursor_visible;
        d.screen.cursor_shape = frame.cursor_shape;
        var content = try d.painter.paint(&d.screen);
        defer content.deinit(d.gpa);
        const c = d.config;
        return term.raster.decorate(d.gpa, &content, .{
            .padding = c.padding,
            .window_bar = c.window_bar,
            .window_bar_size = c.window_bar_size,
            .border_radius = c.border_radius,
            .margin = c.margin,
            .margin_fill = c.margin_fill,
            .title = c.title,
            .title_font = d.title_font,
            .title_color = .{
                .r = c.theme.foreground.r,
                .g = c.theme.foreground.g,
                .b = c.theme.foreground.b,
                .a = 160,
            },
            .shadow_blur = if (c.shadow) 24 else 0,
            .shadow_y = if (c.shadow) 10 else 0,
        });
    }
};

/// The frames to play, in order, with their durations: the loop offset applied, the
/// cursor blinking (every 500ms, a frame split where it changes), and the playback speed.
pub const Timeline = struct {
    items: []Item,

    pub const Item = struct { frame: usize, cursor: bool, duration_ns: u64 };

    pub fn init(arena: Allocator, recording: *const Recording) Allocator.Error!Timeline {
        const config = recording.config;
        var items: std.ArrayList(Item) = .empty;
        const blink: u64 = 500 * std.time.ns_per_ms;
        var clock: u64 = 0;
        for (recording.frames.items, 0..) |frame, i| {
            var left: u64 = @intCast(@max(frame.duration.nanoseconds, 0));
            while (left > 0) {
                const phase_left = if (config.cursor_blink) blink - clock % blink else left;
                const take = @min(left, phase_left);
                const on = !config.cursor_blink or (clock / blink) % 2 == 0;
                try items.append(arena, .{ .frame = i, .cursor = on, .duration_ns = take });
                clock += take;
                left -= take;
            }
        }
        // Start the loop part way in.
        if (config.loop_offset > 0 and items.items.len > 1) {
            var total: u64 = 0;
            for (items.items) |it| total += it.duration_ns;
            const offset: u64 = @intFromFloat(
                @as(f64, @floatFromInt(total)) * config.loop_offset / 100,
            );
            var at: u64 = 0;
            var split: usize = 0;
            for (items.items, 0..) |it, k| {
                if (at + it.duration_ns > offset) {
                    split = k;
                    break;
                }
                at += it.duration_ns;
            }
            std.mem.rotate(Item, items.items, split);
        }
        const speed: f64 = config.playback_speed;
        for (items.items) |*it| it.duration_ns = @intFromFloat(
            @as(f64, @floatFromInt(it.duration_ns)) / speed,
        );
        return .{ .items = items.items };
    }
};

/// Writes the output at `path` (one of `recording`'s), drawn along `timeline`.
pub fn write(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    recording: *const Recording,
    timeline: *const Timeline,
    drawing: *Drawing,
    environ: *const std.process.Environ.Map,
) Error!void {
    switch (kindOf(path) orelse return error.Unsupported) {
        .gif => try writeGif(gpa, io, path, recording, timeline, drawing),
        .png_frames => try writeFrames(gpa, io, path, recording, timeline, drawing),
        .png => try writeLastPng(gpa, io, path, recording, drawing),
        .text => try writeText(gpa, io, path, recording),
        .svg => try writeSvg(gpa, io, path, recording, timeline),
        .video => try writeVideo(gpa, io, path, recording, timeline, drawing, environ),
    }
}

/// Writes the `Screenshot` lines' PNGs.
pub fn writeScreenshots(
    gpa: Allocator,
    io: Io,
    recording: *const Recording,
    drawing: *Drawing,
) Error!void {
    for (recording.screenshots.items) |shot| {
        var img = try drawing.draw(&shot.frame, true);
        defer img.deinit(gpa);
        try savePng(gpa, io, shot.path, &img);
    }
}

fn createFile(io: Io, path: []const u8) Error!Io.File {
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    return Io.Dir.cwd().createFile(io, path, .{}) catch return error.WriteFailed;
}

fn savePng(gpa: Allocator, io: Io, path: []const u8, img: *const term.image.Image) Error!void {
    const file = try createFile(io, path);
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var w = file.writer(io, &buffer);
    term.image.writePng(gpa, &w.interface, img) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
    };
    w.interface.flush() catch return error.WriteFailed;
}

fn writeGif(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    recording: *const Recording,
    timeline: *const Timeline,
    drawing: *Drawing,
) Error!void {
    const file = try createFile(io, path);
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var w = file.writer(io, &buffer);
    var first = try drawing.draw(&recording.frames.items[0], true);
    const dims = .{ first.width, first.height };
    first.deinit(gpa);
    var encoder = term.image.GifEncoder.init(
        gpa,
        &w.interface,
        dims[0],
        dims[1],
        true,
    ) catch return error.WriteFailed;
    // Centiseconds, the remainders carried so the total stays right.
    var carry: u64 = 0;
    var cache: ?struct { frame: usize, cursor: bool, img: term.image.Image } = null;
    defer if (cache) |*c| c.img.deinit(gpa);
    for (timeline.items) |item| {
        const ns = item.duration_ns + carry;
        const cs = ns / (10 * std.time.ns_per_ms);
        carry = ns % (10 * std.time.ns_per_ms);
        if (cs == 0) continue;
        const reuse = if (cache) |c| c.frame == item.frame and c.cursor == item.cursor else false;
        if (!reuse) {
            if (cache) |*c| c.img.deinit(gpa);
            cache = .{
                .frame = item.frame,
                .cursor = item.cursor,
                .img = try drawing.draw(&recording.frames.items[item.frame], item.cursor),
            };
        }
        encoder.add(&cache.?.img, @intCast(cs)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => return error.WriteFailed,
        };
    }
    encoder.finish() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
    };
    w.interface.flush() catch return error.WriteFailed;
}

fn writeFrames(
    gpa: Allocator,
    io: Io,
    dir: []const u8,
    recording: *const Recording,
    timeline: *const Timeline,
    drawing: *Drawing,
) Error!void {
    Io.Dir.cwd().createDirPath(io, dir) catch return error.WriteFailed;
    // Frames at the frame rate, numbered, as a video tool takes them.
    const interval: u64 = std.time.ns_per_s / recording.config.framerate;
    var number: usize = 0;
    var carry: u64 = 0;
    for (timeline.items) |item| {
        var img = try drawing.draw(&recording.frames.items[item.frame], item.cursor);
        defer img.deinit(gpa);
        const total = item.duration_ns + carry;
        const count = total / interval;
        carry = total % interval;
        for (0..count) |_| {
            var name_buffer: [32]u8 = undefined;
            const name = std.fmt.bufPrint(
                &name_buffer,
                "frame-{d:0>5}.png",
                .{number},
            ) catch unreachable;
            const path = try std.fs.path.join(gpa, &.{ dir, name });
            defer gpa.free(path);
            try savePng(gpa, io, path, &img);
            number += 1;
        }
    }
}

fn writeLastPng(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    recording: *const Recording,
    drawing: *Drawing,
) Error!void {
    const frames = recording.frames.items;
    var img = try drawing.draw(&frames[frames.len - 1], true);
    defer img.deinit(gpa);
    try savePng(gpa, io, path, &img);
}

/// The screens one after another, each different from the one before, separated by a
/// rule: vhs's golden-file format.
fn writeText(gpa: Allocator, io: Io, path: []const u8, recording: *const Recording) Error!void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var screen: term.vt.Screen = try .init(gpa, recording.size);
    defer screen.deinit();
    var previous: ?[]u8 = null;
    defer if (previous) |p| gpa.free(p);
    for (recording.frames.items) |frame| {
        @memcpy(screen.grid().cells, frame.cells);
        const text = try screen.textAlloc(gpa);
        if (previous) |p| if (std.mem.eql(u8, p, text)) {
            gpa.free(text);
            continue;
        };
        if (previous) |p| {
            gpa.free(p);
            out.writer.writeByte('\n') catch return error.OutOfMemory;
            for (0..recording.size.width) |_| {
                out.writer.writeAll("─") catch return error.OutOfMemory;
            }
            out.writer.writeByte('\n') catch return error.OutOfMemory;
        }
        out.writer.writeAll(text) catch return error.OutOfMemory;
        previous = text;
    }
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    const file = try createFile(io, path);
    defer file.close(io);
    file.writeStreamingAll(io, out.written()) catch return error.WriteFailed;
}

/// An animated SVG: each frame a group shown in its time by CSS keyframes, text as text.
fn writeSvg(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    recording: *const Recording,
    timeline: *const Timeline,
) Error!void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    var screen: term.vt.Screen = try .init(gpa, recording.size);
    defer screen.deinit();
    recording.config.theme.apply(&screen);
    const font_size: f32 = recording.config.font_size;
    const cell_w = font_size * 0.6;
    const line_h = font_size * 1.25 * recording.config.line_height;
    const pad: f32 = @floatFromInt(recording.config.padding);
    const width = @as(f32, @floatFromInt(recording.size.width)) * cell_w + 2 * pad;
    const height = @as(f32, @floatFromInt(recording.size.height)) * line_h + 2 * pad;
    var total: u64 = 0;
    for (timeline.items) |it| total += it.duration_ns;
    const total_s = @as(f64, @floatFromInt(@max(total, 1))) / 1e9;
    const bg = screen.background;
    writeSvgInner(
        w,
        recording,
        timeline,
        &screen,
        .{ width, height, pad, total_s },
    ) catch return error.OutOfMemory;
    _ = bg;
    const file = try createFile(io, path);
    defer file.close(io);
    file.writeStreamingAll(io, out.written()) catch return error.WriteFailed;
}

fn writeSvgInner(
    w: *Io.Writer,
    recording: *const Recording,
    timeline: *const Timeline,
    screen: *term.vt.Screen,
    dims: struct { f32, f32, f32, f64 },
) Io.Writer.Error!void {
    const bg = screen.background;
    try w.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d:.0}\" height=\"{d:.0}\" " ++
            "viewBox=\"0 0 {d:.0} {d:.0}\">\n",
        .{ dims[0], dims[1], dims[0], dims[1] },
    );
    try w.print(
        "<style>g.f{{visibility:hidden;animation:{d:.3}s step-end infinite}}</style>\n",
        .{dims[3]},
    );
    try w.print(
        "<rect width=\"100%\" height=\"100%\" rx=\"{d}\" fill=\"#{x:0>2}{x:0>2}{x:0>2}\"/>\n",
        .{ recording.config.border_radius, bg.r, bg.g, bg.b },
    );
    // One keyframe animation per frame: visible during its time, hidden otherwise.
    var at: u64 = 0;
    var total: u64 = 0;
    for (timeline.items) |it| total += it.duration_ns;
    for (timeline.items, 0..) |item, k| {
        const start = @as(f64, @floatFromInt(at)) / @as(f64, @floatFromInt(@max(total, 1))) * 100;
        at += item.duration_ns;
        const end = @as(f64, @floatFromInt(at)) / @as(f64, @floatFromInt(@max(total, 1))) * 100;
        try w.print(
            "<style>@keyframes k{d}{{0%{{visibility:hidden}}{d:.4}%{{visibility:visible}}" ++
                "{d:.4}%{{visibility:hidden}}}}#f{d}{{animation-name:k{d}}}</style>\n",
            .{ k, start, end, k, k },
        );
        @memcpy(screen.grid().cells, recording.frames.items[item.frame].cells);
        screen.row = recording.frames.items[item.frame].row;
        screen.column = recording.frames.items[item.frame].column;
        screen.cursor_visible = item.cursor and recording.frames.items[item.frame].cursor_visible;
        try w.print(
            "<g class=\"f\" id=\"f{d}\" transform=\"translate({d:.1} {d:.1})\">\n",
            .{ k, dims[2], dims[2] },
        );
        // The screen's own SVG, without its outer element.
        var inner: Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer inner.deinit();
        try screen.writeSvg(
            &inner.writer,
            .{
                .font_size = @intFromFloat(recording.config.font_size),
                .padding = 0,
                .cursor = true,
                .all_rows = true,
            },
        );
        const svg = inner.written();
        const body_start = (std.mem.indexOf(u8, svg, "/>\n") orelse 0) + 3;
        const body_end = std.mem.lastIndexOf(u8, svg, "</svg>") orelse svg.len;
        try w.writeAll(svg[@min(body_start, body_end)..body_end]);
        try w.writeAll("</g>\n");
    }
    try w.writeAll("</svg>\n");
}

/// MP4 or WebM through ffmpeg: frames piped in as PNG at the frame rate.
fn writeVideo(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    recording: *const Recording,
    timeline: *const Timeline,
    drawing: *Drawing,
    environ: *const std.process.Environ.Map,
) Error!void {
    _ = environ;
    var rate_buffer: [16]u8 = undefined;
    const rate = std.fmt.bufPrint(
        &rate_buffer,
        "{d}",
        .{recording.config.framerate},
    ) catch unreachable;
    var child = std.process.spawn(io, .{
        .argv = &.{
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-f",
            "image2pipe",
            "-framerate",
            rate,
            "-i",
            "-",
            "-pix_fmt",
            "yuv420p",
            "-vf",
            "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            path,
        },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.Unsupported;
    var buffer: [64 * 1024]u8 = undefined;
    var w = child.stdin.?.writer(io, &buffer);
    const interval: u64 = std.time.ns_per_s / recording.config.framerate;
    var carry: u64 = 0;
    for (timeline.items) |item| {
        var img = try drawing.draw(&recording.frames.items[item.frame], item.cursor);
        defer img.deinit(gpa);
        var png: Io.Writer.Allocating = .init(gpa);
        defer png.deinit();
        term.image.writePng(gpa, &png.writer, &img) catch return error.OutOfMemory;
        const total = item.duration_ns + carry;
        carry = total % interval;
        for (0..total / interval) |_| {
            w.interface.writeAll(png.written()) catch return error.WriteFailed;
        }
    }
    w.interface.flush() catch return error.WriteFailed;
    child.stdin.?.close(io);
    child.stdin = null;
    const outcome = child.wait(io) catch return error.WriteFailed;
    switch (outcome) {
        .exited => |code| if (code != 0) return error.WriteFailed,
        else => return error.WriteFailed,
    }
}

const testing = std.testing;

test kindOf {
    try testing.expectEqual(Kind.gif, kindOf("demo.gif").?);
    try testing.expectEqual(Kind.png_frames, kindOf("frames/").?);
    try testing.expectEqual(Kind.text, kindOf("golden.ascii").?);
    try testing.expectEqual(Kind.video, kindOf("x.MP4").?);
    try testing.expectEqual(null, kindOf("x.doc"));
}
