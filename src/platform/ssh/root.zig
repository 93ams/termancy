//! SSH: keys, and a server that runs programs (terminal user interfaces above all) for
//! the people who connect, as Charm's wish does.
//!
//! | name | |
//! |---|---|
//! | `keys` | public keys, fingerprints, `authorized_keys`, signatures; Ed25519 key files |
//! | `Server`, `Session` | the server: logins, sessions with terminals, forwarding |
//! | `Client` | the client: host key checks, logins, commands, shells, `ssh -L` |
//! | `Agent` | an ssh-agent's keys and signatures, over `$SSH_AUTH_SOCK` |
//! | `known_hosts` | OpenSSH's `known_hosts`: host keys checked and recorded |
//! | `connection` | channels and their windows, for either side |
//! | `transport` | the transport layer: key exchange (ML-KEM hybrid), ciphers |
//! | `wire` | SSH's data types, read and written |

const std = @import("std");

pub const keys = @import("keys.zig");
pub const wire = @import("wire.zig");
pub const transport = @import("transport.zig");
pub const connection = @import("connection.zig");
pub const known_hosts = @import("known_hosts.zig");
pub const Server = @import("Server.zig");
pub const Session = Server.Session;
pub const Client = @import("Client.zig");
pub const Agent = @import("Agent.zig");

test {
    std.testing.refAllDecls(keys);
    std.testing.refAllDecls(wire);
    std.testing.refAllDecls(transport);
    std.testing.refAllDecls(Server);
    std.testing.refAllDecls(Client);
    std.testing.refAllDecls(Agent);
    std.testing.refAllDecls(known_hosts);
    std.testing.refAllDecls(connection);
    _ = @import("tests.zig");
}
