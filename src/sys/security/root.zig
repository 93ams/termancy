//! `security` - protected memory for secrets, a path policy for generated files, OAuth 2.0
//! (PKCE, device authorization), WebAuthn, CTAP2 security keys (and Windows Hello, the way
//! to them on Windows), and secrets as words (BIP 39).

const std = @import("std");

pub const secure = @import("secure.zig");
pub const sandbox = @import("sandbox.zig");
pub const oauth = @import("oauth.zig");
pub const webauthn = @import("webauthn.zig");
pub const ctap = @import("ctap.zig");
pub const windows_hello = @import("windows_hello.zig");
pub const cbor = @import("cbor.zig");
pub const mnemonic = @import("mnemonic.zig");
const JsonObject = @import("JsonObject.zig");

test {
    // `refAllDecls` is shallow, so every file is named here; a file missing from this list
    // would have its tests silently skipped.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(secure);
    std.testing.refAllDecls(sandbox);
    std.testing.refAllDecls(oauth);
    std.testing.refAllDecls(webauthn);
    std.testing.refAllDecls(ctap);
    std.testing.refAllDecls(windows_hello);
    std.testing.refAllDecls(cbor);
    std.testing.refAllDecls(mnemonic);
    std.testing.refAllDecls(JsonObject);
}
