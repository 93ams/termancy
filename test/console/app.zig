//! A program for `test/console/conpty.zig` to run at a Windows console: each command uses
//! one of the console APIs `cli` calls, so that a run under a pseudo console checks them.

const std = @import("std");
const cli = @import("cli");
const field = @import("field");
const tui = @import("tui");

fn width(ctx: *cli.Context) !void {
    const columns = cli.terminal.width(ctx.io, std.Io.File.stdout()) orelse 0;
    try ctx.out.print("width {d}\n", .{columns});
}

/// Waits for Ctrl-C, which `cancel_on_interrupt` turns into `error.Canceled`.
fn wait(ctx: *cli.Context) !void {
    try ctx.out.writeAll("waiting\n");
    try ctx.out.flush();
    try ctx.io.sleep(.fromSeconds(30), .awake);
    try ctx.out.writeAll("not interrupted\n");
}

const kernel32 = struct {
    const windows = std.os.windows;
    const CursorInfo = extern struct { size: windows.DWORD, visible: windows.BOOL };
    extern "kernel32" fn GetConsoleCursorInfo(
        output: windows.HANDLE,
        info: *CursorInfo,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetConsoleMode(
        handle: windows.HANDLE,
        mode: *windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetConsoleMode(
        handle: windows.HANDLE,
        mode: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
    const virtual_terminal_processing = 0x4;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) windows.UINT;
    extern "kernel32" fn SetConsoleOutputCP(code_page: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetConsoleCP(code_page: windows.UINT) callconv(.winapi) windows.BOOL;

    fn cursorShown(output: windows.HANDLE) bool {
        var info: CursorInfo = undefined;
        _ = GetConsoleCursorInfo(output, &info);
        return info.visible.toBool();
    }
};

/// Animates a spinner, which hides the cursor, until Ctrl-C; then says whether the console
/// shows the cursor again. `term.live` must show it before the process goes on to end.
fn spin(ctx: *cli.Context) !void {
    const stdout = std.Io.File.stdout();
    var buffer: [1024]u8 = undefined;
    var writer = stdout.writerStreaming(ctx.io, &buffer);
    var spinner: tui.term.live.Spinner = .{ .title = "spinning" };
    const items = [_]tui.term.live.Item{.{ .spinner = &spinner }};
    var mode: std.os.windows.DWORD = 0;
    _ = kernel32.GetConsoleMode(stdout.handle, &mode);
    _ = kernel32.SetConsoleMode(stdout.handle, mode | kernel32.virtual_terminal_processing);
    var display: tui.term.live.Live = .init(&writer.interface, .full, &items);
    display.file = stdout;
    display.io = ctx.io;
    try display.draw(.now(ctx.io, .awake));
    // Without this, the check after Ctrl-C would pass whatever `term.live` did.
    if (kernel32.cursorShown(stdout.handle)) return ctx.fail("the spinner left the cursor shown", .{});
    ctx.io.sleep(.fromSeconds(30), .awake) catch |err| {
        const shown = kernel32.cursorShown(stdout.handle);
        try ctx.out.writeAll(if (shown) "cursor shown\n" else "cursor hidden\n");
        return err;
    };
}

fn tidy(ctx: *cli.Context) !void {
    try ctx.out.writeAll("cleaned up\n");
}

const SecretFlags = struct {
    token: []const u8,
};
const secret_flags = cli.flags(SecretFlags, field.Set(.{field.Spec(SecretFlags){ .fields = .{
    .token = .{ .secret = true },
} }}), .{ .fields = .{
    .token = .{ .prompt = "Token" },
} });

/// The answer's length: the answer itself must not reach the screen.
fn secret(ctx: *cli.Context, flags: SecretFlags) !void {
    try ctx.out.print("got {d} bytes\n", .{flags.token.len});
}

/// Counts timer ticks with no key pressed, then quits on `q`: timers must fire while the
/// program waits on the console, and keys must still arrive.
const Ticker = struct {
    ticks: u32 = 0,

    pub fn start(_: *Ticker) tui.Cmd {
        return .tick(.fromMilliseconds(20), 0);
    }

    pub fn update(model: *Ticker, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .tick => {
                model.ticks += 1;
                if (model.ticks < 5) return .tick(.fromMilliseconds(20), 0);
            },
            .key => |key| if (key.matches("q")) return .quit,
            else => {},
        }
        return .none;
    }

    pub fn view(model: *const Ticker, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // Every cell changes at the end, so the renderer writes the whole line.
        try w.writeAll(if (model.ticks < 5) "ticking\n" else "all five ticks\n");
    }
};

fn ticks(ctx: *cli.Context) !void {
    var buffer: [4096]u8 = undefined;
    var terminal: tui.Terminal = try .open(ctx.io, &buffer);
    defer terminal.close();
    var ticker: Ticker = .{};
    var program: tui.Program(Ticker) = .init(ctx.gpa, &ticker, terminal.writer(), .{});
    defer program.deinit();
    _ = try program.run(&terminal);
    try ctx.out.print("quit after {d} ticks\n", .{ticker.ticks});
}

/// Asks the console which image protocol it speaks, as `termancy image -p auto` does: the
/// answer depends on the console host, but the question must come back within its time.
fn query(ctx: *cli.Context) !void {
    var buffer: [256]u8 = undefined;
    var terminal: tui.Terminal = try .open(ctx.io, &buffer);
    defer terminal.close();
    const protocol = tui.term.graphics.detectByQuery(&terminal, .fromMilliseconds(500));
    try ctx.out.print("protocol {s}\n", .{if (protocol) |p| @tagName(p) else "none"});
}

pub const root = cli.command(.{
    .name = "console",
    .summary = "Console checks",
    .cleanup = tidy,
    .subcommands = .{
        cli.command(.{ .name = "width", .summary = "Print the console's width", .run = width }),
        cli.command(.{ .name = "wait", .summary = "Wait for Ctrl-C", .run = wait }),
        cli.command(.{ .name = "spin", .summary = "Spin until Ctrl-C", .run = spin }),
        cli.command(.{ .name = "ticks", .summary = "Run a program on timers", .run = ticks }),
        cli.command(.{ .name = "query", .summary = "Ask for the image protocol", .run = query }),
        cli.command(.{ .name = "utf8", .summary = "Print text outside ASCII", .run = utf8 }),
        cli.command(.{
            .name = "secret",
            .summary = "Ask for a token without showing it",
            .flags = secret_flags,
            .run = secret,
        }),
    },
});

/// Text outside ASCII, which a console on a default code page garbles unless `App.run`
/// switches it to UTF-8.
fn utf8(ctx: *cli.Context) !void {
    try ctx.out.writeAll("value: çà ✓\n");
}

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root, .cancel_on_interrupt = true };
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 1;
    // `utf8` runs on a console left at code page 437, as on a default US install, and
    // checks afterwards that `App.run` put it back.
    const at_437 = args.len > 1 and std.mem.eql(u8, args[1], "utf8");
    if (at_437) {
        _ = kernel32.SetConsoleOutputCP(437);
        _ = kernel32.SetConsoleCP(437);
    }
    const status = app.run(init);
    if (at_437) std.debug.print("code page {d} after\n", .{kernel32.GetConsoleOutputCP()});
    return status;
}
