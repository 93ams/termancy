const std = @import("std");

pub const OpenApiGenerator = struct {
    pub fn generateJson(writer: anytype, comptime cmd: anytype) !void {
        try writer.print(
            \\{{
            \\  "openapi": "3.0.0",
            \\  "info": {{
            \\    "title": "{s}",
            \\    "description": "{s}",
            \\    "version": "1.0.0"
            \\  }},
            \\  "paths": {{
        , .{ cmd.name, cmd.description });

        const is_type = @TypeOf(cmd) == type;
        const has_subs = comptime if (is_type)
            @hasDecl(cmd, "subcommands")
        else if (@typeInfo(@TypeOf(cmd)) == .@"struct")
            @hasField(@TypeOf(cmd), "subcommands") or @hasDecl(@TypeOf(cmd), "subcommands")
        else
            false;

        var first_path = true;

        if (has_subs) {
            inline for (cmd.subcommands) |sub| {
                if (!first_path) try writer.writeAll(",");
                first_path = false;

                try writer.print(
                    \\
                    \\    "/{s}": {{
                    \\      "post": {{
                    \\        "summary": "{s}",
                    \\        "responses": {{
                    \\          "200": {{
                    \\            "description": "Success"
                    \\          }}
                    \\        }}
                    \\      }}
                    \\    }}
                , .{ sub.name, sub.description });
            }
        } else {
            try writer.print(
                \\
                \\    "/": {{
                \\      "post": {{
                \\        "summary": "{s}",
                \\        "responses": {{
                \\          "200": {{
                \\            "description": "Success"
                \\          }}
                \\        }}
                \\      }}
                \\    }}
            , .{cmd.description});
        }

        try writer.writeAll("\n  }\n}\n");
    }
};
