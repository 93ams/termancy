//! The web: a terminal in the browser, as ttyd and gotty serve one.
//!
//! | name | |
//! |---|---|
//! | `Server`, `Session` | the server: a page, a WebSocket per session, `Session.next` |
//! | `Client` | a minimal WebSocket client, for tests and scripts |
//! | `page` | the page it serves: xterm.js, from jsDelivr, pinned and checked |

const std = @import("std");

pub const Server = @import("Server.zig");
pub const Session = Server.Session;
pub const page = Server.page;
pub const Client = @import("Client.zig");

test {
    std.testing.refAllDecls(Server);
    std.testing.refAllDecls(Client);
}
