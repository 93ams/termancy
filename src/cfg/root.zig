//! `cfg` - load, layer, query, decode, and write configuration.
//!
//! ```zig
//! const cfg = @import("cfg");
//!
//! const Settings = struct {
//!     server: struct { host: []const u8 = "localhost", port: u16 = 8080 } = .{},
//!     token: ?[]const u8 = null,
//! };
//!
//! // What the fields mean, from `field` specs; how they are spelled, per place.
//! const app = cfg.settings(Settings, field.Set(.{field.Spec(Settings){ .fields = .{
//!     .token = .{ .help = "API token", .secret = true },
//! } }}), .{ .fields = .{ .token = .{ .env = "APP_TOKEN" } } });
//!
//! var config: cfg.Config = try .initFor(app, gpa);
//! defer config.deinit();
//! if (try config.findFile(io, .{
//!     .name = "app",
//!     .dirs = &.{ ".", "$HOME/.config/app" },
//! })) |file| {
//!     try config.loadFile(io, .cwd(), file, null, &diag);
//! }
//! config.useEnv(environ);
//! try config.automaticEnv("APP");               // APP_SERVER_PORT=9000
//! const settings = try config.decode(app, .{}, &diag);
//! ```
//!
//! Formats: JSON (and JSON with comments), TOML, YAML, dotenv, ZON, and INI (see `Format`).
//!
//! Defaults may also come from a `.zon` file, which the compiler checks against the struct
//! when it is imported, so a misspelled or mistyped default does not build:
//!
//! ```zig
//! const defaults: Settings = @import("defaults.zon"); // .{ .server = .{ .port = 9000 } }
//! try config.setDefaults(app, defaults);
//! ```
//!
//! The module imports `std` and `field`, whose specs it shares with `cli`. It shares one
//! convention with `cli` besides: any type with
//! `pub fn parse(text: []const u8) !T` decodes from text, so `Duration` and `ByteSize`
//! work as configuration fields and as flag types.

const std = @import("std");

/// Layers of configuration (defaults, files, environment, flags), queried and decoded.
pub const Config = @import("Config.zig");
/// Where and why a parse or a decode failed.
pub const Diagnostic = @import("Diagnostic.zig");
/// A configuration tree: a table, array, string, number, boolean, or null.
pub const Value = value.Value;
/// A tree's table: keys in insertion order.
pub const Table = value.Table;
/// A tree's array.
pub const Array = value.Array;
/// A configuration format: what `Format.fromPath` names, and its `parse` and `write`.
pub const Format = internal.format.Format;
/// A span of time, written `1h30m`, `500ms`: a field and flag type.
pub const Duration = internal.scalar.Duration;
/// A count of bytes, written `10MiB`, `1.5GB`: a field and flag type.
pub const ByteSize = internal.scalar.ByteSize;
/// A date and time, as TOML and RFC 3339 write it.
pub const DateTime = internal.scalar.DateTime;

/// Decodes a tree into a settings type or a plain Zig type. See `decode.zig`.
pub const decode = decoding.decode;
/// Encodes a Zig value into a tree, each field under its own name.
pub const encode = decoding.encode;
/// Encodes a value under the keys a settings type gives its fields.
pub const encodeAs = decoding.encodeAs;
/// A settings type: a struct, what its fields mean (a `field.Set` of specs), and the keys
/// they are spelled with. See `settings.zig`.
pub const settings = settings_.settings;
/// The spellings `settings` takes: each field's key, old key, variable, and merging.
pub const Keys = settings_.Keys;
/// How a list combines across layers.
pub const Merge = settings_.Merge;
/// Where else each value of a settings type can be set, for a command's help.
pub const sourcesOf = settings_.sourcesOf;
/// How `decode` treats unknown keys, bounds, and warnings.
pub const DecodeOptions = decoding.Options;
/// What `decode` can fail with.
pub const DecodeError = decoding.Error;
/// Infers the type of untyped text: `true`, `42`, `1.5`, or a string.
pub const infer = internal.scalar.infer;
/// Whether text matches a pattern where `*` matches any run of bytes and `?` one byte, as
/// `.glob` checks and ignore lists use: `glob(".*", ".cache")`.
pub const glob = decoding.glob;
/// The leaves that differ between two trees. See `diff.zig`.
pub const diff = differ.diff;
/// One leaf that differs, as `diff` reports it.
pub const Change = differ.Change;

/// The tree: `Value` and its operations.
pub const value = @import("value.zig");
/// Dotted key paths: `server.port`, `servers.0.host`, `"a.b".c`.
pub const path = @import("path.zig");
/// JSON, and JSON with comments.
pub const json = @import("json.zig");
/// TOML 1.0.
pub const toml = @import("toml.zig");
/// YAML 1.2, without the parts configuration does not use.
pub const yaml = @import("yaml.zig");
/// `.env` files.
pub const dotenv = @import("dotenv.zig");
/// ZON, Zig's object notation.
pub const zon = @import("zon.zig");
/// INI files.
pub const ini = @import("ini.zig");
/// JSON Schema for a settings struct, and checking a tree against one.
pub const schema = @import("schema.zig");
/// Changing a document in place, keeping its comments and layout.
pub const edit = @import("edit.zig");
/// Where a key is written in a document: its line and column.
pub const locate = @import("locate.zig");
/// Encrypted configuration files.
pub const encrypted = @import("encrypted.zig");
/// Upgrading documents between schema versions.
pub const migrate = @import("migrate.zig");
const decoding = @import("decode.zig");
const differ = @import("diff.zig");
const settings_ = @import("settings.zig");

/// The library's own parts, public for its files and for the curious, but not stable:
/// they change in any release (see docs/stability.md).
pub const internal = struct {
    pub const format = @import("format.zig");
    pub const scalar = @import("scalar.zig");
};

test {
    // `refAllDecls` is shallow, so every file is named here; a file missing from this list
    // would have its tests silently skipped.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Config);
    std.testing.refAllDecls(settings_);
    std.testing.refAllDecls(differ);
    std.testing.refAllDecls(edit);
    std.testing.refAllDecls(locate);
    std.testing.refAllDecls(encrypted);
    std.testing.refAllDecls(migrate);
    std.testing.refAllDecls(Diagnostic);
    std.testing.refAllDecls(value);
    std.testing.refAllDecls(path);
    std.testing.refAllDecls(internal.format);
    std.testing.refAllDecls(json);
    std.testing.refAllDecls(toml);
    std.testing.refAllDecls(yaml);
    std.testing.refAllDecls(dotenv);
    std.testing.refAllDecls(zon);
    std.testing.refAllDecls(ini);
    std.testing.refAllDecls(internal.scalar);
    std.testing.refAllDecls(schema);
    std.testing.refAllDecls(decoding);
    _ = @import("fuzz.zig");
}
