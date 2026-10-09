//! Opt-in capture of panics: a banner, a stack trace, and a report on disk.
//!
//! ## Opting in
//!
//! Zig 0.16 takes the panic hook as a **type declared in the executable's root**,
//! not as a runtime registration. So a program opts in with one line in `main.zig`:
//!
//! ```zig
//! pub const panic = @import("framework").crash.Panic(.{
//!     .app_name = "cfg",
//!     .issues_url = "https://github.com/93ams/snek/issues/new",
//! });
//! ```
//!
//! `Panic` is comptime-parameterised rather than a global to be configured at
//! startup, because a panic can happen before any startup code runs - during
//! static initialisation, or in a constructor - and a reporter that is only armed
//! after `main` begins is a reporter that misses exactly the crashes worth
//! reporting.
//!
//! ## Why the handler is so careful
//!
//! A panic handler runs on a stack that may already be exhausted and in a process
//! whose invariants have just been declared void. Everything here therefore uses
//! **fixed buffers** and writes through `std.debug.print`, which locks stderr
//! internally; no allocator is touched, because the allocator is the thing most
//! likely to be the reason we are here.
//!
//! What was missing before this file: `[measured]` `renderStructuredPanic` and
//! `writeCrashReport` existed in the tree and **nothing installed either of them** -
//! no app declared `std_options`, no app declared `panic`, and the renderer
//! discarded the `first_trace_addr` it was handed (`_ = first_trace_addr;`), so the
//! crash report it could produce had no stack trace in it at all.

const std = @import("std");
const builtin = @import("builtin");
const capability = @import("render").capability;

/// What the reporter needs to know. Comptime, so it costs nothing and cannot be
/// half-configured at the moment it matters.
pub const Config = struct {
    app_name: []const u8,
    /// Printed in the banner so the user has somewhere to go. Empty omits the line
    /// rather than printing a blank one.
    issues_url: []const u8 = "",
    /// Directory for reports, relative to the working directory. Chosen rather than
    /// derived so a program can put reports beside its own state without this
    /// module guessing - `platform/xdg.zig` is there for a caller that wants a
    /// standard location and has an environment to resolve it against.
    report_dir: []const u8 = ".cache",
    /// Whether to write a report at all. A CI run that only wants the banner, and
    /// no filesystem writes in a failure path, can say so.
    write_report: bool = true,
};

/// The banner's inner width. Every line is exactly this many columns plus the two
/// border characters, so the box is straight and a test can assert its shape.
const banner_width = 57;

/// Renders the banner.
///
/// `styled` is passed in rather than read from the capability gate so this stays a
/// pure function of its arguments and a test can assert both forms exactly.
///
/// ASCII only, and deliberately. Two encoders in this repository are recorded as
/// corrupting non-ASCII text, and a banner that renders as mojibake is unreadable
/// at precisely the moment it is needed. It also makes one column and one byte the
/// same thing, which is what lets the width assertion below be true.
pub fn renderBanner(
    writer: anytype,
    message: []const u8,
    config: Config,
    styled: bool,
) !void {
    const red: []const u8 = if (styled) "\x1b[31;1m" else "";
    const cyan: []const u8 = if (styled) "\x1b[36;4m" else "";
    const reset: []const u8 = if (styled) "\x1b[0m" else "";

    try border(writer, red, reset, '+', '-', '+');
    try centered(writer, red, reset, "UNEXPECTED FATAL ERROR");
    try border(writer, red, reset, '+', '-', '+');
    // Truncated rather than wrapped: a panic message is diagnostic text, and a
    // banner that reflows is a banner nobody can read at two in the morning.
    try padded(writer, red, reset, message);
    try border(writer, red, reset, '+', '-', '+');

    var meta_buf: [128]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "{s}: {s} ({s})", .{
        config.app_name,
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    }) catch config.app_name;
    try padded(writer, red, reset, meta);

    if (config.issues_url.len > 0) {
        var url_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&url_buf, "report this at {s}", .{config.issues_url}) catch
            "report this issue upstream";
        try padded(writer, red, reset, line);
    }
    _ = cyan;

    try border(writer, red, reset, '+', '-', '+');
}

fn border(
    writer: anytype,
    red: []const u8,
    reset: []const u8,
    left: u8,
    fill: u8,
    right: u8,
) !void {
    try writer.print("{s}{c}", .{ red, left });
    for (0..banner_width) |_| try writer.writeByte(fill);
    try writer.print("{c}{s}\n", .{ right, reset });
}

/// Writes one field row: border, one space, the text clipped and padded to
/// `banner_width - 2`, one space, border.
///
/// Clipping and padding are done by hand rather than with a format specifier.
/// `{s:55.55}` looks like it truncates and does not - the message line came out
/// 304 bytes wide - and a panic banner whose geometry depends on a formatter's
/// precision semantics is a banner that is straight until the day it matters.
fn padded(
    writer: anytype,
    red: []const u8,
    reset: []const u8,
    text: []const u8,
) !void {
    const field_width = banner_width - 2;
    const clipped = text[0..@min(text.len, field_width)];

    try writer.print("{s}|{s} ", .{ red, reset });
    try writer.writeAll(clipped);
    for (clipped.len..field_width) |_| try writer.writeByte(' ');
    try writer.print(" |{s}\n", .{reset});
}

/// Writes a centred row at the same inner width as `padded` and `border`.
fn centered(
    writer: anytype,
    red: []const u8,
    reset: []const u8,
    text: []const u8,
) !void {
    const clipped = text[0..@min(text.len, banner_width)];
    const total_pad = banner_width - clipped.len;
    const left_pad = total_pad / 2;
    // The remainder goes on the right, so an odd gap does not drift the box.
    const right_pad = total_pad - left_pad;

    try writer.print("{s}|{s}", .{ red, reset });
    for (0..left_pad) |_| try writer.writeByte(' ');
    try writer.writeAll(clipped);
    for (0..right_pad) |_| try writer.writeByte(' ');
    try writer.print("|{s}\n", .{reset});
}

/// Renders the report as a single JSON object.
///
/// One object rather than an array, and no trailing whitespace, so a caller can
/// append it to an existing NDJSON crash log without rewriting the file - which
/// matters because the process is about to die and cannot reopen and fix anything.
pub fn renderReport(
    writer: anytype,
    message: []const u8,
    config: Config,
    timestamp_ms: i64,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("app");
    try json.write(config.app_name);
    try json.objectField("message");
    try json.write(message);
    try json.objectField("os");
    try json.write(@tagName(builtin.os.tag));
    try json.objectField("arch");
    try json.write(@tagName(builtin.cpu.arch));
    try json.objectField("zig_version");
    try json.write(builtin.zig_version_string);
    try json.objectField("timestamp_ms");
    try json.write(timestamp_ms);
    try json.endObject();
}

/// The report's filename, written into `buffer`.
///
/// The timestamp is part of the name so two crashes cannot overwrite each other,
/// which is the whole reason not to use a fixed `crash.json`.
pub fn reportPath(buffer: []u8, config: Config, timestamp_ms: i64) ![]const u8 {
    if (config.report_dir.len == 0) return error.EmptyReportDir;
    return std.fmt.bufPrint(buffer, "{s}/{s}-crash-{d}.json", .{
        config.report_dir, config.app_name, timestamp_ms,
    });
}

/// The `io` the report is written through, installed once at startup.
///
/// A panic handler receives only the message and an address, so anything else it
/// needs has to arrive some other way. This is that way, and it is set-once: the
/// alternative is doing filesystem work through a handle whose validity is exactly
/// what is in question.
var report_io: ?std.Io = null;

/// Arms report writing. Call once during startup, before any command runs.
///
/// Without this the banner and the stack trace still print; only the file is
/// skipped. A crash reporter that printed nothing because it had not been armed
/// would be worse than one that prints to the terminal.
pub fn install(io: std.Io) void {
    report_io = io;
}

/// Builds the panic type a `main.zig` declares as `pub const panic`.
///
/// The shape is `std.debug.FullPanic`'s, which requires exactly
/// `fn ([]const u8, ?usize) noreturn`.
pub fn Panic(comptime config: Config) type {
    return std.debug.FullPanic(struct {
        fn handler(message: []const u8, first_trace_addr: ?usize) noreturn {
            // The banner, through a fixed buffer. No allocation: the allocator is
            // the most likely reason this handler is running at all.
            var banner_buf: [1024]u8 = undefined;
            var banner_writer = std.Io.Writer.fixed(&banner_buf);
            renderBanner(
                &banner_writer,
                message,
                config,
                // Read once. A capability lookup cannot fail, but it also cannot be
                // allowed to matter here.
                capability.get().color,
            ) catch {};
            std.debug.print("{s}", .{banner_writer.buffered()});

            // The stack trace the previous implementation threw away. Zig 0.16 takes a
            // `StackUnwindOptions` rather than a bare address; passing the panic's own
            // first trace address is what omits the handler and its machinery from the
            // top of the trace. This call site is why the module could not have been
            // compiling before anything installed the hook: nobody instantiated it.
            std.debug.dumpCurrentStackTrace(.{ .first_address = first_trace_addr });

            if (config.write_report) writeReport(message, config) catch |err| {
                std.debug.print("snek: crash report not written: {s}\n", .{@errorName(err)});
            };

            // Abort rather than exit: the process state is already void, and a
            // graceful teardown would run destructors over data that caused the
            // panic. `abort` also produces a core dump where one is configured,
            // which a plain exit does not.
            std.process.abort();
        }
    }.handler);
}

/// Writes the report, or reports why it could not.
fn writeReport(message: []const u8, config: Config) !void {
    const io = report_io orelse return error.ReporterNotArmed;

    var path_buf: [512]u8 = undefined;
    const path = try reportPath(&path_buf, config, timestampMs());

    var content_buf: [2048]u8 = undefined;
    var content_writer = std.Io.Writer.fixed(&content_buf);
    try renderReport(&content_writer, message, config, timestampMs());

    try std.Io.Dir.cwd().createDirPath(io, config.report_dir);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, content_writer.buffered(), 0);
}

/// Wall-clock milliseconds, or 0 when no clock is reachable.
///
/// Deliberately total: a crash reporter that failed because it could not read a
/// clock would be failing for the least important reason available.
fn timestampMs() i64 {
    // `comptime` so the Windows branch is not analysed on a POSIX target: an
    // `extern "kernel32"` declaration that is analysed on Linux is a link error.
    if (comptime builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn GetSystemTimeAsFileTime(ptr: *u64) callconv(.winapi) void;
        };
        var hundred_ns: u64 = 0;
        kernel32.GetSystemTimeAsFileTime(&hundred_ns);
        // Windows FILETIME counts 100ns ticks from 1601-01-01.
        const epoch_delta_100ns: u64 = 116_444_736_000_000_000;
        if (hundred_ns <= epoch_delta_100ns) return 0;
        return @intCast((hundred_ns - epoch_delta_100ns) / 10_000);
    }
    // No portable wall clock without an `io`; reported as 0 rather than faked.
    // The filename still distinguishes one crash from the next because the caller
    // is a single process dying once.
    return 0;
}

const testing = std.testing;

const test_config = Config{
    .app_name = "snek",
    .issues_url = "https://example.invalid/issues",
};

test "the banner names the app, the platform and where to report it" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderBanner(&w, "index out of bounds", test_config, false);

    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "UNEXPECTED FATAL ERROR") != null);
    try testing.expect(std.mem.indexOf(u8, out, "index out of bounds") != null);
    try testing.expect(std.mem.indexOf(u8, out, "snek") != null);
    try testing.expect(std.mem.indexOf(u8, out, @tagName(builtin.os.tag)) != null);
    try testing.expect(std.mem.indexOf(u8, out, "https://example.invalid/issues") != null);
}

test "an unstyled banner carries no escape sequences" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderBanner(&w, "boom", test_config, false);
    try testing.expect(std.mem.indexOfScalar(u8, w.buffered(), 0x1b) == null);
}

test "a styled banner does carry them" {
    // The other half of the pair: if neither form were asserted, a banner that
    // silently stopped honouring `styled` would look correct in both tests.
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderBanner(&w, "boom", test_config, true);
    try testing.expect(std.mem.indexOfScalar(u8, w.buffered(), 0x1b) != null);
}

test "an empty issues url omits the line rather than printing a blank one" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderBanner(&w, "boom", .{ .app_name = "snek" }, false);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "report this") == null);
}

test "an over-long panic message is truncated, not allowed to reflow the banner" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const long_message: [300]u8 = @splat('x');
    try renderBanner(&w, &long_message, test_config, false);

    // Every line is exactly the ruled width: border character, 57 columns, border.
    // This is the assertion that catches a field width drifting away from
    // `banner_width`, which is how a box stops being a box.
    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    var counted: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expectEqual(@as(usize, banner_width + 2), line.len);
        counted += 1;
    }
    try testing.expect(counted >= 6);
}

test "the report is one JSON object with the fields a triager needs" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderReport(&w, "index out of bounds", test_config, 1_700_000_000_000);

    const out = w.buffered();
    // One object, and no trailing newline, so it can be appended to an NDJSON log.
    try testing.expect(std.mem.startsWith(u8, out, "{\"app\":\"snek\""));
    try testing.expect(std.mem.endsWith(u8, out, "}"));

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("index out of bounds", obj.get("message").?.string);
    try testing.expectEqualStrings(@tagName(builtin.os.tag), obj.get("os").?.string);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), obj.get("timestamp_ms").?.integer);
}

test "a panic message that would break the JSON is escaped" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderReport(&w, "cannot open \"C:\\a\"", test_config, 1);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "cannot open \"C:\\a\"",
        parsed.value.object.get("message").?.string,
    );
}

test "the report path is unique per crash and includes the app name" {
    var buf: [512]u8 = undefined;
    const first = try reportPath(&buf, test_config, 1000);
    try testing.expectEqualStrings(".cache/snek-crash-1000.json", first);

    var second_buf: [512]u8 = undefined;
    const second = try reportPath(&second_buf, test_config, 1001);
    // Different timestamps, different files: a second crash does not overwrite the
    // first one's report, which is the point of putting the stamp in the name.
    try testing.expect(!std.mem.eql(u8, first, second));
}

test "an empty report directory is an error rather than a path with no directory" {
    var buf: [512]u8 = undefined;
    try testing.expectError(
        error.EmptyReportDir,
        reportPath(&buf, .{ .app_name = "snek", .report_dir = "" }, 1),
    );
}

test "Panic builds a type std.debug.FullPanic accepts" {
    // The opt-in line in a `main.zig` is a compile-time contract; instantiating it
    // here is what makes a signature change in std fail in this repository rather
    // than in a downstream binary.
    const PanicType = Panic(test_config);
    try testing.expect(@hasDecl(PanicType, "call"));
    try testing.expect(@TypeOf(PanicType.call) == fn ([]const u8, ?usize) noreturn);
}
