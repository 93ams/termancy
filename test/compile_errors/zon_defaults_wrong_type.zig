//! Must not compile: `.zon` defaults whose value does not fit the field type, as
//! `cfg.Config.setDefaults` documents. The compiler checks the file when it is imported.

const Settings = struct {
    server: struct {
        host: []const u8 = "localhost",
        port: u16 = 8080,
    } = .{},
};

const defaults: Settings = @import("zon_defaults_wrong_type.zon");

comptime {
    _ = defaults;
}
