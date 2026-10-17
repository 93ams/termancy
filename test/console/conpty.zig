//! Runs a program under a Windows pseudo console and checks what it shows, so that the
//! console code in `cli` (width, hidden prompts, Ctrl-C) runs against a real console host:
//!
//!     conpty.exe <columns> <step>... -- <program> <arg>...
//!
//! Steps, in order: `expect:TEXT` waits (up to ten seconds) until the screen output holds
//! TEXT; `send:TEXT` types TEXT, where `\r` is Enter and `\x03` is Ctrl-C. At the end,
//! `forbid:TEXT` fails if the output ever held TEXT, and `exit:N` checks the exit status.
//! Exits 0 when every step holds; otherwise prints what went wrong and the output.

const std = @import("std");

const HANDLE = *anyopaque;
const BOOL = i32;

const Coord = extern struct { x: i16, y: i16 };

const StartupInfo = extern struct {
    cb: u32,
    reserved: ?[*:0]u16 = null,
    desktop: ?[*:0]u16 = null,
    title: ?[*:0]u16 = null,
    x: u32 = 0,
    y: u32 = 0,
    x_size: u32 = 0,
    y_size: u32 = 0,
    x_count_chars: u32 = 0,
    y_count_chars: u32 = 0,
    fill_attribute: u32 = 0,
    flags: u32 = 0,
    show_window: u16 = 0,
    reserved2_len: u16 = 0,
    reserved2: ?*u8 = null,
    std_input: ?HANDLE = null,
    std_output: ?HANDLE = null,
    std_error: ?HANDLE = null,
};

const StartupInfoEx = extern struct {
    info: StartupInfo,
    attributes: ?*anyopaque,
};

const ProcessInformation = extern struct {
    process: HANDLE,
    thread: HANDLE,
    process_id: u32,
    thread_id: u32,
};

const extended_startupinfo_present = 0x00080000;
const proc_thread_attribute_pseudoconsole = 0x00020016;
const startf_usestdhandles = 0x00000100;

extern "kernel32" fn CreatePipe(
    read: *HANDLE,
    write: *HANDLE,
    attributes: ?*anyopaque,
    size: u32,
) callconv(.winapi) BOOL;
extern "kernel32" fn CreatePseudoConsole(
    size: Coord,
    input: HANDLE,
    output: HANDLE,
    flags: u32,
    console: *HANDLE,
) callconv(.winapi) i32;
extern "kernel32" fn ClosePseudoConsole(console: HANDLE) callconv(.winapi) void;
extern "kernel32" fn InitializeProcThreadAttributeList(
    list: ?*anyopaque,
    count: u32,
    flags: u32,
    size: *usize,
) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(
    list: *anyopaque,
    flags: u32,
    attribute: usize,
    value: ?*anyopaque,
    size: usize,
    previous: ?*anyopaque,
    returned: ?*usize,
) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(
    application: ?[*:0]const u16,
    command_line: ?[*:0]u16,
    process_attributes: ?*anyopaque,
    thread_attributes: ?*anyopaque,
    inherit_handles: BOOL,
    flags: u32,
    environment: ?*anyopaque,
    directory: ?[*:0]const u16,
    startup: *StartupInfo,
    information: *ProcessInformation,
) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*anyopaque, add: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(
    file: HANDLE,
    buffer: [*]u8,
    len: u32,
    read: *u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(
    file: HANDLE,
    buffer: [*]const u8,
    len: u32,
    written: ?*u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetModuleFileNameW(
    module: ?HANDLE,
    name: [*]u16,
    size: u32,
) callconv(.winapi) u32;

/// `path` as Windows names it. Under WSL, the paths this program is given are Linux paths;
/// it runs from the Linux file system too, so the Windows name of its own file starts with
/// the prefix that maps one to the other (`\\\\wsl.localhost\\<distro>`).
fn windowsPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0 or path[0] != '/') return path;
    var name: [1024]u16 = undefined;
    const len = GetModuleFileNameW(null, &name, name.len);
    const own = try std.unicode.wtf16LeToWtf8Alloc(arena, name[0..len]);
    // `\\server\share\...`, where the server is `wsl.localhost` or `wsl$`.
    if (!std.mem.startsWith(u8, own, "\\\\")) return path;
    var parts = std.mem.splitScalar(u8, own[2..], '\\');
    const server = parts.next() orelse return path;
    const share = parts.next() orelse return path;
    const wsl = std.ascii.eqlIgnoreCase(server, "wsl.localhost") or
        std.ascii.eqlIgnoreCase(server, "wsl$");
    if (!wsl) return path;
    const tail = try std.mem.replaceOwned(u8, arena, path, "/", "\\");
    return std.fmt.allocPrint(arena, "\\\\{s}\\{s}{s}", .{ server, share, tail });
}

/// The console's output, filled by `drain` on its own thread; `written` publishes it.
var screen: [1 << 20]u8 = undefined;
var written: std.atomic.Value(usize) = .init(0);

fn drain(output: HANDLE) void {
    var len: usize = 0;
    while (len < screen.len) {
        var got: u32 = 0;
        const room: u32 = @intCast(@min(screen.len - len, 4096));
        if (ReadFile(output, screen[len..].ptr, room, &got, null) == 0 or got == 0) break;
        len += got;
        written.store(len, .release);
    }
}

fn shown() []const u8 {
    return screen[0..written.load(.acquire)];
}

/// `\r`, `\n`, `\\`, and `\xNN` in `text`.
fn unescape(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\' or i + 1 == text.len) {
            try out.append(arena, text[i]);
            continue;
        }
        i += 1;
        switch (text[i]) {
            'r' => try out.append(arena, '\r'),
            'n' => try out.append(arena, '\n'),
            'x' => {
                if (i + 2 >= text.len) return error.BadEscape;
                try out.append(arena, try std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16));
                i += 2;
            },
            else => try out.append(arena, text[i]),
        }
    }
    return out.items;
}

fn fail(comptime format: []const u8, args: anytype) u8 {
    std.debug.print("conpty: " ++ format ++ "\n", args);
    std.debug.print("--- output ---\n{f}\n--------------\n", .{
        std.ascii.hexEscape(shown(), .lower),
    });
    return 1;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 4) {
        std.debug.print("usage: conpty <columns> <step>... -- <program> <arg>...\n", .{});
        return 2;
    }
    const columns = try std.fmt.parseInt(i16, argv[1], 10);
    var split: usize = 2;
    while (split < argv.len and !std.mem.eql(u8, argv[split], "--")) split += 1;
    if (split + 1 >= argv.len) return error.MissingProgram;
    const steps = argv[2..split];

    // The command line, each argument quoted (the arguments here have no quotes).
    var line: std.ArrayList(u8) = .empty;
    for (argv[split + 1 ..], 0..) |arg, i| {
        if (i > 0) try line.append(arena, ' ');
        const word = if (i == 0) try windowsPath(arena, arg) else arg;
        try line.print(arena, "\"{s}\"", .{word});
    }
    const command_line = try std.unicode.wtf8ToWtf16LeAllocZ(arena, line.items);

    var input_read: HANDLE = undefined;
    var input_write: HANDLE = undefined;
    var output_read: HANDLE = undefined;
    var output_write: HANDLE = undefined;
    if (CreatePipe(&input_read, &input_write, null, 0) == 0) return error.CreatePipe;
    if (CreatePipe(&output_read, &output_write, null, 0) == 0) return error.CreatePipe;
    var console: HANDLE = undefined;
    const size: Coord = .{ .x = columns, .y = 30 };
    if (CreatePseudoConsole(size, input_read, output_write, 0, &console) < 0) {
        return error.CreatePseudoConsole;
    }
    // The pseudo console holds its own references to its ends of the pipes.
    _ = CloseHandle(input_read);
    _ = CloseHandle(output_write);
    const reader = try std.Thread.spawn(.{}, drain, .{output_read});

    var list_size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &list_size);
    const list = try arena.alignedAlloc(u8, .of(usize), list_size);
    if (InitializeProcThreadAttributeList(list.ptr, 1, 0, &list_size) == 0) {
        return error.AttributeList;
    }
    if (UpdateProcThreadAttribute(
        list.ptr,
        0,
        proc_thread_attribute_pseudoconsole,
        console,
        @sizeOf(HANDLE),
        null,
        null,
    ) == 0) return error.AttributeList;
    var startup: StartupInfoEx = .{
        // Null standard handles, so that the program gets the pseudo console's rather
        // than inheriting this program's, which a build runner redirects to pipes.
        .info = .{ .cb = @sizeOf(StartupInfoEx), .flags = startf_usestdhandles },
        .attributes = list.ptr,
    };
    // Whether Ctrl-C is ignored is inherited; a shell or build runner that ignores it
    // would pass that on, and the program would never see the Ctrl-C a step sends.
    _ = SetConsoleCtrlHandler(null, 0);
    var process: ProcessInformation = undefined;
    if (CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        0,
        extended_startupinfo_present,
        null,
        null,
        &startup.info,
        &process,
    ) == 0) {
        std.debug.print("conpty: cannot start {s} (error {d}; started as {s})\n", .{
            line.items, GetLastError(), argv[0],
        });
        return 1;
    }

    var forbidden: std.ArrayList([]const u8) = .empty;
    var expected_exit: ?u32 = null;
    for (steps) |step| {
        const colon = std.mem.indexOfScalar(u8, step, ':') orelse return error.BadStep;
        const kind = step[0..colon];
        const text = try unescape(arena, step[colon + 1 ..]);
        if (std.mem.eql(u8, kind, "expect")) {
            var waited: u32 = 0;
            while (std.mem.indexOf(u8, shown(), text) == null) : (waited += 50) {
                if (waited >= 10_000) return fail("timed out waiting for \"{s}\"", .{text});
                Sleep(50);
            }
        } else if (std.mem.eql(u8, kind, "send")) {
            if (WriteFile(input_write, text.ptr, @intCast(text.len), null, null) == 0) {
                return fail("could not type \"{s}\"", .{text});
            }
        } else if (std.mem.eql(u8, kind, "forbid")) {
            try forbidden.append(arena, text);
        } else if (std.mem.eql(u8, kind, "exit")) {
            expected_exit = try std.fmt.parseInt(u32, text, 10);
        } else return error.BadStep;
    }

    if (WaitForSingleObject(process.process, 10_000) != 0) {
        return fail("the program did not exit", .{});
    }
    var code: u32 = 0;
    _ = GetExitCodeProcess(process.process, &code);
    // Closing the pseudo console ends the output, which ends `drain`.
    ClosePseudoConsole(console);
    reader.join();
    for (forbidden.items) |text| {
        if (std.mem.indexOf(u8, shown(), text) != null) return fail("\"{s}\" was shown", .{text});
    }
    if (expected_exit) |want| if (code != want) {
        return fail("exit status {d}, expected {d}", .{ code, want });
    };
    return 0;
}
