//! A guestbook served over SSH, as Charm's wish serves Bubble Tea programs: everyone who
//! connects gets the same `tui` program in their own terminal, and what one signs, the
//! others see. It shows:
//!
//! - `sys.ssh.Server`: logins by public key (or anyone, for a demo), one task per
//!   session, the session's terminal type and size;
//! - `sys.web.Server`: the same lobby in a browser tab (`--web`), behind a token;
//! - `tui.runSession`: a program run over a remote session instead of a terminal,
//!   resizes and all;
//! - state shared between sessions, behind an `Io.Mutex`, refreshed on a timer;
//! - `term.Style` borders with a title and a gradient (Lip Gloss's border blend), and the
//!   registry's `input` and `stopwatch` components;
//! - tests: keys through `tui.testing.Driver`, the screen against a golden file
//!   (`TERMANCY_UPDATE_GOLDEN=1 zig build examples` rewrites it), and the session path with a
//!   scripted session.
//!
//!     zig build examples
//!     zig-out/bin/lobby serve --anyone          # then, elsewhere: ssh -p 2323 ada@localhost
//!     zig-out/bin/lobby serve -k ~/.ssh/authorized_keys
//!     zig-out/bin/lobby serve --anyone --web 127.0.0.1:7681   # and open the link it prints
//!     zig-out/bin/lobby preview --user ada

const std = @import("std");
const cli = @import("cli");
const tui = @import("tui");
const term = @import("term");
const sys = @import("sys");
const components = @import("components");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ssh = sys.ssh;
const web = sys.web;

/// What everyone has signed, shared by every session.
pub const Guestbook = struct {
    gpa: Allocator,
    io: Io,
    lock: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct { user: []const u8, text: []const u8 };

    pub fn deinit(book: *Guestbook) void {
        for (book.entries.items) |e| {
            book.gpa.free(e.user);
            book.gpa.free(e.text);
        }
        book.entries.deinit(book.gpa);
    }

    pub fn sign(book: *Guestbook, user: []const u8, text: []const u8) Allocator.Error!void {
        book.lock.lockUncancelable(book.io);
        defer book.lock.unlock(book.io);
        const entry: Entry = .{
            .user = try book.gpa.dupe(u8, user),
            .text = try book.gpa.dupe(u8, text),
        };
        try book.entries.append(book.gpa, entry);
    }

    /// The last `n` entries, copied into `out` (the strings stay the book's: entries are
    /// never removed).
    pub fn latest(book: *Guestbook, out: []Entry) []Entry {
        book.lock.lockUncancelable(book.io);
        defer book.lock.unlock(book.io);
        const items = book.entries.items;
        const n = @min(out.len, items.len);
        @memcpy(out[0..n], items[items.len - n ..]);
        return out[0..n];
    }

    pub fn count(book: *Guestbook) usize {
        book.lock.lockUncancelable(book.io);
        defer book.lock.unlock(book.io);
        return book.entries.items.len;
    }
};

const refresh_tick = 1;

/// One visitor's view of the lobby.
pub const Lobby = struct {
    user: []const u8,
    book: *Guestbook,
    draft: components.input.Input,
    here: components.stopwatch.Stopwatch = .{ .keys = false },
    width: u16 = 60,
    shown: [5]Guestbook.Entry = undefined,
    shown_len: usize = 0,

    pub fn init(gpa: Allocator, user: []const u8, book: *Guestbook) Lobby {
        return .{
            .user = user,
            .book = book,
            .draft = .{
                .gpa = gpa,
                .prompt = "sign: ",
                .placeholder = "a message, then enter",
                .char_limit = 60,
            },
        };
    }

    pub fn deinit(lobby: *Lobby) void {
        lobby.draft.deinit();
    }

    pub fn start(lobby: *Lobby) tui.Cmd {
        lobby.refresh();
        return .batch(&.{ lobby.here.start(), .every(.fromMilliseconds(500), refresh_tick) });
    }

    fn refresh(lobby: *Lobby) void {
        lobby.shown_len = lobby.book.latest(&lobby.shown).len;
    }

    pub fn update(lobby: *Lobby, msg: tui.Msg) tui.Cmd {
        switch (msg) {
            .key => |key| {
                if (key.matches("esc") or key.matches("ctrl+c")) return .quit;
                if (key.matches("enter")) {
                    const text = std.mem.trim(u8, lobby.draft.value(), " ");
                    if (text.len > 0) {
                        lobby.book.sign(lobby.user, text) catch {};
                        lobby.draft.setValue("") catch {};
                        lobby.refresh();
                    }
                    return .none;
                }
                _ = lobby.draft.handleKey(key);
            },
            .paste => |text| lobby.draft.insert(text) catch {},
            .resize => |size| lobby.width = size.width,
            .tick => |id| {
                if (id != refresh_tick) return lobby.here.update(msg);
                lobby.refresh();
            },
            else => {},
        }
        return .none;
    }

    pub fn view(lobby: *const Lobby, w: *Io.Writer) Io.Writer.Error!void {
        var body_buffer: [2048]u8 = undefined;
        var body: Io.Writer = .fixed(&body_buffer);
        const dim: term.Style = .{ .dim = true };
        const name: term.Style = .{ .fg = .hex(0xff5f87), .bold = true };
        body.writeAll("Welcome, ") catch {};
        name.paint(&body, lobby.user) catch {};
        body.writeAll(". You have been here ") catch {};
        lobby.here.view(&body) catch {};
        body.writeAll(".\n\n") catch {};
        if (lobby.shown_len == 0) {
            dim.paint(&body, "Nobody has signed yet.") catch {};
        } else {
            for (lobby.shown[0..lobby.shown_len]) |entry| {
                name.paint(&body, entry.user) catch {};
                body.print(": {s}\n", .{entry.text}) catch {};
            }
        }
        const frame: term.Style = .{
            .border = .rounded,
            .border_title = "lobby",
            .border_blend = &.{ .hex(0xff5f87), .hex(0x5fafff) },
            .padding = .symmetric(0, 1),
            .width = @min(@as(usize, lobby.width), 64) -| 2,
        };
        try frame.render(w, std.mem.trimEnd(u8, body.buffered(), "\n"));
        try w.writeByte('\n');
        try lobby.draft.view(w);
        try w.writeByte('\n');
        try dim.paint(w, "enter signs • esc leaves");
    }
};

// Serving.

const ServeFlags = struct {
    listen: []const u8 = "127.0.0.1:2323",
    authorized_keys: ?[]const u8 = null,
    anyone: bool = false,
    web: ?[]const u8 = null,
    pub const meta = .{
        .listen = .{ .short = 'l', .help = "The address and port to listen on" },
        .web = .{ .help = "Open it to browsers too, on this address and port (they need " ++
            "the link it prints, token and all)" },
        .authorized_keys = .{ .short = 'k', .help = "Who may come in (an authorized_keys file)" },
        .anyone = .{ .help = "Let anyone in, without a key" },
    };
};

const Served = struct {
    book: *Guestbook,
    allowed: []const ssh.keys.Authorized,
    gpa: Allocator,
    io: Io,
};

fn serve(ctx: *cli.Context, flags: ServeFlags) !void {
    if (!flags.anyone and flags.authorized_keys == null)
        return ctx.usageError("say who may come in: -k <authorized_keys>, or --anyone", .{});
    const address = Io.net.IpAddress.parseLiteral(flags.listen) catch
        return ctx.usageError("--listen {s}: give host:port", .{flags.listen});
    var allowed: []const ssh.keys.Authorized = &.{};
    if (flags.authorized_keys) |path| {
        const cwd = Io.Dir.cwd();
        const text = cwd.readFileAlloc(ctx.io, path, ctx.arena, .limited(1 << 20)) catch |err|
            return ctx.fail("{s}: {s}", .{ path, @errorName(err) });
        allowed = try ssh.keys.parseAuthorizedKeys(ctx.arena, text);
    }
    var book: Guestbook = .{ .gpa = ctx.gpa, .io = ctx.io };
    defer book.deinit();
    var served: Served = .{ .book = &book, .allowed = allowed, .gpa = ctx.gpa, .io = ctx.io };
    // A real server keeps its host key (see `termancy serve`); a demo makes one each run.
    const host_key: ssh.keys.KeyPair = .generate(ctx.io);
    const host = flags.listen[0 .. std.mem.lastIndexOfScalar(u8, flags.listen, ':') orelse 0];
    try ctx.err.print("the lobby is open on {s}: ssh -p {d} <name>@{s}\n", .{
        flags.listen, address.getPort(), host,
    });

    // Browsers, alongside: their own listener and task, the same book.
    const token = web.Server.newToken(ctx.io);
    const web_config: web.Server.Config = .{
        .handler = web.Server.handlerFor(Served, visitFromBrowser),
        .context = &served,
        .token = &token,
        .title = "lobby",
    };
    var web_listener: ?Io.net.Server = null;
    defer if (web_listener) |*l| l.deinit(ctx.io);
    var browsers: Io.Group = .init;
    defer browsers.cancel(ctx.io);
    if (flags.web) |text| {
        const web_address = Io.net.IpAddress.parseLiteral(text) catch
            return ctx.usageError("--web {s}: give host:port", .{text});
        web_listener = web_address.listen(ctx.io, .{ .reuse_address = true }) catch |err|
            return ctx.fail("{s}: {s}", .{ text, @errorName(err) });
        const listener = &web_listener.?;
        try ctx.err.print("and to browsers: {f}\n", .{
            web.Server.link(listener.socket.address, &web_config),
        });
        browsers.concurrent(ctx.io, serveBrowsers, .{ &served, listener, &web_config }) catch |err|
            return ctx.fail("--web: {s}", .{@errorName(err)});
    }
    ssh.Server.listen(ctx.gpa, ctx.io, address, .{
        .host_key = host_key,
        .handler = visit,
        .context = &served,
        .public_key = if (flags.anyone) null else allow,
        .anyone = flags.anyone,
    }) catch |err| return ctx.fail("{s}: {s}", .{ flags.listen, @errorName(err) });
}

fn serveBrowsers(
    served: *Served,
    listener: *Io.net.Server,
    config: *const web.Server.Config,
) void {
    web.Server.serve(served.gpa, served.io, listener, config) catch {};
}

fn allow(context: ?*anyopaque, _: []const u8, key: ssh.keys.PublicKey) bool {
    const served: *Served = @ptrCast(@alignCast(context.?));
    for (served.allowed) |a| if (a.key.eql(key)) return true;
    return false;
}

/// One SSH session: the lobby, on their terminal.
fn visit(context: ?*anyopaque, session: *ssh.Session) anyerror!void {
    if (session.pty == null) {
        try session.writeStderr("the lobby needs a terminal: ssh -t\r\n");
        return error.NoTerminal;
    }
    try welcome(@ptrCast(@alignCast(context.?)), session, session.user);
}

/// One browser tab: the lobby, for a guest.
fn visitFromBrowser(served: *Served, session: *web.Session) anyerror!void {
    try welcome(served, session, "guest");
}

/// The lobby on `session` (an SSH or a web session), for `user`, at its size.
fn welcome(served: *Served, session: anytype, user: []const u8) !void {
    var lobby: Lobby = .init(served.gpa, user, served.book);
    defer lobby.deinit();
    _ = try tui.runSession(served.gpa, served.io, &lobby, session, .{ .alt_screen = true });
}

// Previewing, without a network: the first frame on a virtual terminal.

const PreviewFlags = struct {
    user: []const u8 = "ada",
    pub const meta = .{ .user = .{ .help = "Who is visiting" } };
};

fn preview(ctx: *cli.Context, flags: PreviewFlags) !void {
    var book: Guestbook = .{ .gpa = ctx.gpa, .io = ctx.io };
    defer book.deinit();
    try book.sign("grace", "hello from the other side");
    var driver: tui.testing.Driver(Lobby) = try .init(ctx.gpa, .init(ctx.gpa, flags.user, &book), .{
        .program = .{
            .size = .{ .width = 60, .height = 10 },
            .capability = .{ .color = .none, .escapes = true },
        },
        .io = ctx.io,
    });
    defer driver.deinit();
    try ctx.out.writeAll(try driver.screenTextTrimmed(ctx.arena));
}

pub const root = cli.command(.{
    .name = "lobby",
    .summary = "A guestbook served over SSH",
    .subcommands = .{
        cli.command(.{
            .name = "serve",
            .summary = "Open the lobby to SSH",
            .flags = ServeFlags,
            .run = serve,
        }),
        cli.command(.{
            .name = "preview",
            .summary = "Print what a visitor sees first",
            .flags = PreviewFlags,
            .run = preview,
        }),
    },
});

pub fn main(init: std.process.Init) u8 {
    const app: cli.App = .{ .root = &root };
    return app.run(init);
}

const testing = std.testing;
const Driver = tui.testing.Driver(Lobby);

test "signing adds to the book, and the screen matches its golden file" {
    var book: Guestbook = .{ .gpa = testing.allocator, .io = testing.io };
    defer book.deinit();
    var d: Driver = try .init(testing.allocator, .init(testing.allocator, "ada", &book), .{
        .program = .{ .size = .{ .width = 60, .height = 10 } },
    });
    defer d.deinit();
    try d.expectFrameContains("Nobody has signed yet.");
    try d.typeText("hi all");
    try d.press("enter");
    try testing.expectEqual(1, book.count());
    try d.expectFrameContains("ada: hi all");
    try d.advance(.fromSeconds(3));
    try d.expectScreenGolden("examples/lobby/testdata/signed.golden");
    try d.press("esc");
    try testing.expect(d.done());
}

test "another visitor's signature shows on the next refresh" {
    var book: Guestbook = .{ .gpa = testing.allocator, .io = testing.io };
    defer book.deinit();
    var d: Driver = try .init(testing.allocator, .init(testing.allocator, "ada", &book), .{});
    defer d.deinit();
    try book.sign("grace", "hello");
    try testing.expect(try d.advanceUntil("grace: hello", .fromMilliseconds(100), .fromSeconds(1)));
}

test "over a session: typed input, a resize, and leaving" {
    const Event = ssh.Server.Event;
    const Scripted = struct {
        events: []const Event,
        index: usize = 0,
        pub fn next(s: *@This(), _: Io.Timeout) Io.Cancelable!Event {
            if (s.index == s.events.len) return .closed;
            s.index += 1;
            return s.events[s.index - 1];
        }
    };
    var book: Guestbook = .{ .gpa = testing.allocator, .io = testing.io };
    defer book.deinit();
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var lobby: Lobby = .init(testing.allocator, "bob", &book);
    defer lobby.deinit();
    var program: tui.Program(Lobby) = .init(testing.allocator, &lobby, &out.writer, .{});
    defer program.deinit();
    var session: Scripted = .{ .events = &.{
        .{ .data = "on my way" },
        .{ .data = "\r" },
        .{ .resize = .{ .width = 40, .height = 12 } },
        .{ .data = "\x1b" },
    } };
    _ = try program.runSession(testing.io, &session);
    try testing.expectEqual(1, book.count());
    try testing.expectEqual(40, lobby.width);
    try testing.expect(program.done());
}

test "over a browser's socket: its size, typed input, and leaving" {
    const io = testing.io;
    var book: Guestbook = .{ .gpa = testing.allocator, .io = io };
    defer book.deinit();
    var served: Served = .{ .book = &book, .allowed = &.{}, .gpa = testing.allocator, .io = io };
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const address = listener.socket.address;
    const config: web.Server.Config = .{
        .handler = web.Server.handlerFor(Served, visitFromBrowser),
        .context = &served,
        .token = "",
        .anyone = true,
    };
    var serving = try io.concurrent(serveBrowsers, .{ &served, &listener, &config });
    defer serving.cancel(io);

    var origin: [64]u8 = undefined;
    var client: web.Client = undefined;
    const from = try std.fmt.bufPrint(&origin, "http://{f}", .{address});
    try testing.expectEqual(101, try client.open(io, address, "/ws", from));
    defer client.close();
    try client.send(.text, "{\"type\":\"resize\",\"cols\":40,\"rows\":12}");
    try client.send(.binary, "on my way\r");
    var screen: std.ArrayList(u8) = .empty;
    defer screen.deinit(testing.allocator);
    while (std.mem.indexOf(u8, screen.items, ": on my way") == null) {
        const m = try client.receive();
        try testing.expectEqual(.binary, m.opcode);
        try screen.appendSlice(testing.allocator, m.data);
    }
    try client.send(.binary, "\x1b");
    while (true) {
        const m = try client.receive();
        if (m.opcode != .text) continue;
        try testing.expectEqualStrings("{\"type\":\"exit\",\"status\":0}", m.data);
        break;
    }
    var entries: [1]Guestbook.Entry = undefined;
    const signed = book.latest(&entries);
    try testing.expectEqual(1, signed.len);
    try testing.expectEqualStrings("guest", signed[0].user);
    // The frame fits the browser's 40 columns, so the welcome wraps (at 80, it would not).
    try testing.expect(std.mem.indexOf(u8, screen.items, "been here   \x1b[") != null);
}

test "preview prints the first frame" {
    const app: cli.App = .{ .root = &root };
    const result = try cli.testing.run(app, &.{ "preview", "--user", "lin" }, .{});
    defer result.deinit();
    try testing.expectEqual(0, result.status);
    try testing.expect(std.mem.indexOf(u8, result.out, "Welcome, lin.") != null);
    try testing.expect(std.mem.indexOf(u8, result.out, "grace: hello from the other side") != null);
}
