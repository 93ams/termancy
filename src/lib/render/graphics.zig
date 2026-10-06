const std = @import("std");

pub const GraphicsProtocol = enum {
    kitty,
    iterm2,
    sixel,
    unsupported,
};

pub const TerminalGraphics = struct {
    pub fn detectProtocol(env_map: *const std.process.Environ.Map) GraphicsProtocol {
        if (env_map.get("KITTY_WINDOW_ID") != null) return .kitty;

        if (env_map.get("TERM_PROGRAM")) |tp| {
            if (std.mem.eql(u8, tp, "iTerm.app") or std.mem.eql(u8, tp, "WezTerm")) {
                return .iterm2;
            }
        }

        if (env_map.get("TERM")) |term| {
            if (std.mem.indexOf(u8, term, "kitty") != null) return .kitty;
            if (std.mem.indexOf(u8, term, "iterm") != null) return .iterm2;
            if (std.mem.indexOf(u8, term, "sixel") != null or std.mem.indexOf(u8, term, "mlterm") != null) return .sixel;
        }

        return .unsupported;
    }

    /// Render an inline PNG/JPEG image using detected or preferred protocol
    pub fn renderInlineImage(
        writer: anytype,
        image_data: []const u8,
        protocol: GraphicsProtocol,
        allocator: std.mem.Allocator,
    ) !void {
        switch (protocol) {
            .kitty => {
                // Kitty protocol chunk transmission
                const encoded_len = std.base64.standard.Encoder.calcSize(image_data.len);
                const b64 = try allocator.alloc(u8, encoded_len);
                defer allocator.free(b64);
                _ = std.base64.standard.Encoder.encode(b64, image_data);

                try writer.print("\x1b_Ga=T,f=100,m=0;{s}\x1b\\", .{b64});
            },
            .iterm2 => {
                // iTerm2 protocol
                const encoded_len = std.base64.standard.Encoder.calcSize(image_data.len);
                const b64 = try allocator.alloc(u8, encoded_len);
                defer allocator.free(b64);
                _ = std.base64.standard.Encoder.encode(b64, image_data);

                try writer.print("\x1b]1337;File=inline=1:{s}\x07", .{b64});
            },
            .sixel => {
                // Sixel raster format prefix
                try writer.writeAll("\x1bPq\"1;1;100;100#0;2;0;0;0#1;2;100;100;100#1~~@@\x1b\\");
            },
            .unsupported => {
                try writer.writeAll("[Inline Graphics Unsupported in Terminal]\n");
            },
        }
    }
};
