//! `cli.Defaults.from`: flag defaults from a configuration, such as a `cfg.Config`,
//! without a hand-written lookup.
//!
//! ```zig
//! var config: cfg.Config = .init(gpa);
//! try config.loadFile(io, .cwd(), "tool.toml", null, null);
//! const app: cli.App = .{ .root = &root, .defaults = .from(&config, .{}) };
//! ```
//!
//! The key of a flag is the path of the command that declares it, without the root, then
//! the flag's long name: `tool serve --port` reads `serve.port`, and a persistent flag of
//! the root reads its bare name. `Options.prefix` puts a section in front (`tool.serve.port`);
//! a flag's `.key` meta replaces the whole key. The value is used only when the flag is
//! given neither on the command line nor in its environment variable.
//!
//! `cli` does not import `cfg`: the source is any pointer whose type has
//! `fn flagText(source, key: []const u8) ?[]const u8` (or `!?[]const u8`, an error counting
//! as no value), giving the value as it would be typed after the flag. `cfg.Config` has it.

const std = @import("std");
const Command = @import("Command.zig");
const Flag = @import("Flag.zig");
const parse = @import("parse.zig");

/// Where `from` looks a flag's key up.
pub const Options = struct {
    /// The section every key starts with: `"tool"` reads `tool.serve.port`.
    prefix: []const u8 = "",
    /// How messages name where a bad value came from, such as the file's name.
    name: []const u8 = "config",
};

/// Keys longer than this are not looked up.
pub const max_key = 256;

/// Defaults read from `source`, a pointer to a value with a `flagText` method, which must
/// outlive the run.
pub fn from(source: anytype, comptime options: Options) parse.Defaults {
    const Source = @TypeOf(source);
    if (@typeInfo(Source) != .pointer or @typeInfo(Source).pointer.size != .one) {
        @compileError("cli.Defaults.from: the source must be a pointer, found " ++
            @typeName(Source));
    }
    const Child = @typeInfo(Source).pointer.child;
    if (!@hasDecl(Child, "flagText")) {
        @compileError("cli.Defaults.from: " ++ @typeName(Child) ++
            " has no flagText(key) method");
    }
    return .{
        .context = @ptrCast(@constCast(source)),
        .lookup = &struct {
            fn lookup(
                context: ?*anyopaque,
                path: []const *const Command,
                flag: *const Flag,
            ) ?[]const u8 {
                const typed: Source = @ptrCast(@alignCast(context.?));
                var buffer: [max_key]u8 = undefined;
                const key = keyOf(&buffer, options.prefix, path, flag) orelse return null;
                const found = typed.flagText(key);
                return if (@typeInfo(@TypeOf(found)) == .error_union) found catch null else found;
            }
        }.lookup,
        .name = options.name,
    };
}

/// The key `flag` of the command `path` is read from, in `buffer`; null when it does not
/// fit.
pub fn keyOf(
    buffer: []u8,
    prefix: []const u8,
    path: []const *const Command,
    flag: *const Flag,
) ?[]const u8 {
    if (flag.key) |key| return key;
    var w: std.Io.Writer = .fixed(buffer);
    w.writeAll(prefix) catch return null;
    const owner = declaring(path, flag);
    for (path[1 .. owner + 1]) |cmd| separated(&w, cmd.name) catch return null;
    separated(&w, flag.name) catch return null;
    return w.buffered();
}

fn separated(w: *std.Io.Writer, segment: []const u8) std.Io.Writer.Error!void {
    if (w.end > 0) try w.writeByte('.');
    try w.writeAll(segment);
}

/// The index in `path` of the command that declares `flag`: the leaf, unless an ancestor's
/// persistent flag.
fn declaring(path: []const *const Command, flag: *const Flag) usize {
    for (path, 0..) |cmd, i| {
        for (cmd.flags) |*own| if (own == flag) return i;
        for (cmd.persistent_flags) |*own| if (own == flag) return i;
    }
    return path.len - 1;
}

const testing = std.testing;

test keyOf {
    const check = struct {
        fn always(_: []const u8) bool {
            return true;
        }
    }.always;
    const port: Flag = .{ .name = "port", .field = "port", .kind = .value, .check = check };
    const renamed: Flag = .{
        .name = "host",
        .field = "host",
        .kind = .value,
        .check = check,
        .key = "net.host",
    };
    const root: Command = .{ .name = "tool" };
    const serve: Command = .{ .name = "serve" };
    var buffer: [max_key]u8 = undefined;
    const path = [_]*const Command{ &root, &serve };
    try testing.expectEqualStrings("serve.port", keyOf(&buffer, "", &path, &port).?);
    try testing.expectEqualStrings("tool.serve.port", keyOf(&buffer, "tool", &path, &port).?);
    try testing.expectEqualStrings("port", keyOf(&buffer, "", path[0..1], &port).?);
    try testing.expectEqualStrings("net.host", keyOf(&buffer, "tool", &path, &renamed).?);
    var small: [8]u8 = undefined;
    try testing.expectEqual(null, keyOf(&small, "", &path, &port));
}
