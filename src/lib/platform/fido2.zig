const std = @import("std");

pub const Fido2Prompt = struct {
    challenge: [32]u8,
    relying_party: []const u8,

    pub fn init(relying_party: []const u8, challenge: [32]u8) Fido2Prompt {
        return .{
            .challenge = challenge,
            .relying_party = relying_party,
        };
    }

    pub fn promptUser(self: Fido2Prompt, writer: anytype) !void {
        try writer.print("\n\x1b[33;1m[SECURITY KEY]\x1b[0m Please touch your security key for '{s}'...\n", .{self.relying_party});
    }
};
