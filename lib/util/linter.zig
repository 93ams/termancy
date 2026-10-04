const std = @import("std");

pub const ComptimeLinter = struct {
    pub fn lintFlags(comptime FlagsType: type) void {
        if (FlagsType == void) return;
        if (!@hasDecl(FlagsType, "meta")) return;

        const meta = FlagsType.meta;
        const fields = std.meta.fields(FlagsType);

        // Check for duplicate short flags
        inline for (fields, 0..) |f1, i| {
            if (@hasField(@TypeOf(meta), f1.name)) {
                const m1 = @field(meta, f1.name);
                if (@hasField(@TypeOf(m1), "short")) {
                    const s1 = m1.short;
                    inline for (fields[i + 1 ..]) |f2| {
                        if (@hasField(@TypeOf(meta), f2.name)) {
                            const m2 = @field(meta, f2.name);
                            if (@hasField(@TypeOf(m2), "short")) {
                                const s2 = m2.short;
                                if (s1 == s2) {
                                    @compileError("CLI Flag Collision: Flags '" ++ f1.name ++ "' and '" ++ f2.name ++ "' share duplicate shorthand '-" ++ [_]u8{s1} ++ "'");
                                }
                            }
                        }
                    }
                }
            }
        }
    }
};
