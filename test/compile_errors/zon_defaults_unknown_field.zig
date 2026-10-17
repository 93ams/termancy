//! Must not compile: `.zon` defaults naming a field the settings struct lacks, as
//! `cfg.Config.setDefaults` documents. The compiler checks the file when it is imported.

const Settings = struct {
    server: struct {
        host: []const u8 = "localhost",
        port: u16 = 8080,
    } = .{},
};

const defaults: Settings = @import("zon_defaults_unknown_field.zon");

comptime {
    _ = defaults;
}
