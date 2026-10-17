//! A layered configuration store.
//!
//! Sources are kept in separate layers and combined on demand into the *effective* tree.
//! From lowest to highest precedence:
//!
//! | layer      | filled by                                     |
//! |------------|-----------------------------------------------|
//! | `default`  | `setDefault`, `setDefaults`                   |
//! | `file`     | `loadFile`, `loadSource` (merged in order)    |
//! | `profile`  | `useProfile`: the `profiles.<name>` table     |
//! | `env`      | `useEnv` + `automaticEnv` / `bindEnv`         |
//! | `flag`     | `bindFlags`, `setFlag`                        |
//! | `override` | `set`                                         |
//!
//! Tables merge deeply across layers; anything else replaces.
//!
//! Memory: everything a `Config` loads lives in its own arena and is freed by `deinit`. The
//! effective tree lives in a second arena that is reset whenever it is rebuilt, so a
//! `Value` or string returned by `get` and friends is valid **until the next call that
//! changes the configuration**. `decode` copies into the long-lived arena instead, so its
//! result lives until `deinit`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = @import("value.zig").Value;
const Array = @import("value.zig").Array;
const Format = @import("format.zig").Format;
const Diagnostic = @import("Diagnostic.zig");
const decoding = @import("decode.zig");
const dotenv = @import("dotenv.zig");
const path = @import("path.zig");
const scalar = @import("scalar.zig");
const differ = @import("diff.zig");
const encrypted = @import("encrypted.zig");
const json = @import("json.zig");
const yaml = @import("yaml.zig");
const locator = @import("locate.zig");

const Config = @This();

/// Where a value comes from, lowest first: each layer overrides the ones before it.
pub const Layer = enum {
    default,
    file,
    profile,
    env,
    flag,
    override,

    const count = @typeInfo(Layer).@"enum".field_names.len;
};

/// Where an effective value came from.
pub const Origin = struct {
    layer: Layer,
    /// The file path, environment variable, or flag name; empty for `default` and
    /// `override`.
    source: []const u8 = "",

    /// Writes the layer, and the file, variable, or flag in parentheses when known.
    pub fn format(origin: Origin, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll(@tagName(origin.layer));
        if (origin.source.len > 0) try writer.print(" ({s})", .{origin.source});
    }
};

/// Written in place of a secret value.
pub const redacted = "<redacted>";

/// Files larger than this are refused by `loadFile`.
pub const max_file_size = 16 * 1024 * 1024;

gpa: Allocator,
/// Long-lived: layers, their sources, settings, decoded results.
arena: std.heap.ArenaAllocator,
/// The `file` layer and its sources, rebuilt from `files` whenever one changes.
file_arena: std.heap.ArenaAllocator,
/// Every loaded source, in load order, each in its own arena so `reload` can replace it.
files: std.ArrayList(FileSource) = .empty,
/// Short-lived: the effective tree and its origins, reset on every rebuild.
cache: std.heap.ArenaAllocator,

layers: [Layer.count]Value = @splat(.empty_table),
/// For the `file` and `flag` layers: leaf path -> file path or flag name.
sources: [Layer.count]std.StringArrayHashMapUnmanaged([]const u8) = @splat(.empty),

environ: ?*const std.process.Environ.Map = null,
automatic_env: bool = false,
env_prefix: []const u8 = "",
/// Key path -> environment variable name, from `bindEnv`.
env_bindings: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
/// Key paths that have no value in any layer but should still be looked up in the
/// environment: registered by `decode` and `registerKeys`.
known_keys: std.StringArrayHashMapUnmanaged(void) = .empty,
secrets: std.StringArrayHashMapUnmanaged(void) = .empty,
/// Key paths whose lists accumulate across files and layers (`setMerge`).
appends: std.StringArrayHashMapUnmanaged(void) = .empty,
/// Keys compare without regard to ASCII case (`ignoreKeyCase`).
case_insensitive: bool = false,
/// `set`s patched into the effective tree since it was last rebuilt. Each allocates in the
/// cache arena, which only a rebuild resets, so after `max_patches` the next one rebuilds.
patches: u8 = 0,
/// `${key}` in a value is replaced with the value at `key` (`useReferences`).
references: bool = false,
/// The first reference that could not be expanded in the last `resolve`.
reference_problem: ?ReferenceProblem = null,
/// With references: the effective tree before they were expanded, in the cache arena.
unexpanded: ?Value = null,
/// With references: for each key a reference names, the keys whose values name it, so a
/// `set` re-expands only what depends on the key it changes. In the cache arena.
dependents: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
/// Where `${secret:<scheme>:<name>}` looks secrets up, by scheme, beside `env` and `file`.
secret_providers: std.StringArrayHashMapUnmanaged(SecretProvider) = .empty,
/// `${name:argument}` resolvers that are not secrets (`addResolver`).
resolvers: std.StringArrayHashMapUnmanaged(SecretProvider) = .empty,
/// The top-level key listing files to include (`useIncludes`); null when off.
include_key: ?[]const u8 = null,
/// Opens encrypted files (`usePassphrase`). Borrowed, not copied.
passphrase: ?[]const u8 = null,

profile: ?[]const u8 = null,
/// The table that holds profiles. It is not part of the effective tree.
profiles_key: []const u8 = "profiles",

effective: ?Value = null,
/// What the `profile` and `env` layers contributed to the effective tree. Those two layers are
/// derived during `resolve` rather than stored, so `write(.{ .layer })` reads them from here.
derived_profile: Value = .empty_table,
derived_env: Value = .empty_table,
origins: std.StringArrayHashMapUnmanaged(Origin) = .empty,

/// One loaded file or source.
const FileSource = struct {
    /// Holds `name`, `tree`, and the source text.
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    tree: Value,
    format: Format,
    /// How `reload` gets it again.
    from: From,
    /// Loaded through another file's include: `reload` reaches it from that file again,
    /// or not at all if the file no longer includes it.
    included: bool = false,
    /// The file's size and modification time when read, for `changed`.
    stamp: ?Stamp = null,
    /// The text parsed, to point at keys in it (`locateDiagnostic`); empty when it was
    /// read as a stream or from a `Source`.
    text: []const u8 = "",

    const Stamp = struct { size: u64, mtime: i96, inode: Io.File.INode };

    const From = union(enum) {
        /// `loadSource`: the text given, which a reload keeps.
        text,
        /// `loadFile`: `name` in this directory.
        file: Io.Dir,
        /// `loadFrom`.
        source: Source,
    };
};

/// Somewhere configuration comes from besides files: an HTTP endpoint, Consul, Vault, a
/// cloud parameter store. Implementations live outside `cfg`, so that a program pays for
/// network code only when it uses it; `loadFrom` merges what `load` returns into the
/// `file` layer, and `reload` calls it again.
pub const Source = struct {
    context: ?*anyopaque = null,
    /// For `explain` and messages, such as `consul:app/config`.
    name: []const u8,
    /// Returns a table, allocated in `arena`. An error fails the load; describe it in
    /// `diag` when there is more to say than the error's name.
    load: *const fn (
        context: ?*anyopaque,
        io: Io,
        arena: Allocator,
        diag: ?*Diagnostic,
    ) anyerror!Value,
};

/// An empty configuration. All memory comes from `gpa` and is freed by `deinit`.
///
/// To return decoded settings from a helper, give it an arena the caller owns, such as a
/// `cli.Context`'s, and skip `deinit`: what `decode` returns then lives as long as that
/// arena, with no copy.
///
/// ```zig
/// fn load(ctx: *cli.Context) !Settings {
///     var config: cfg.Config = .init(ctx.arena); // freed with the arena: no deinit
///     ...
///     return config.decode(Settings, .{}, &diag);
/// }
/// ```
pub fn init(gpa: Allocator) Config {
    return .{ .gpa = gpa, .arena = .init(gpa), .cache = .init(gpa), .file_arena = .init(gpa) };
}

/// Frees everything the configuration loaded or returned, including `decode` results.
pub fn deinit(config: *Config) void {
    for (config.files.items) |*file| file.arena.deinit();
    config.files.deinit(config.gpa);
    config.file_arena.deinit();
    config.cache.deinit();
    config.arena.deinit();
    config.* = undefined;
}

fn invalidate(config: *Config) void {
    config.effective = null;
}

// -- Sources ---------------------------------------------------------------------------

/// What setting a value can fail with: a malformed key, or a key through a non-table.
pub const SetError = error{ InvalidPath, NotATable, IndexOutOfRange, Unrepresentable } ||
    Allocator.Error;

/// Sets a default for `key_path`. `value` is any encodable Zig value or a `Value`.
pub fn setDefault(config: *Config, key_path: []const u8, value: anytype) SetError!void {
    try config.putEncoded(.default, key_path, value);
}

/// Sets every field of a struct as a default, registers the keys `T.meta` marks secret,
/// and binds the environment variables it names with `.env` (see `bindEnv`).
///
/// Defaults can live in a `.zon` file next to the source, checked against the struct by
/// the compiler: a missing, misspelled, or mistyped field is a compile error.
///
/// ```zig
/// const defaults: Settings = @import("defaults.zon");
/// try config.setDefaults(defaults);
/// ```
pub fn setDefaults(config: *Config, value: anytype) SetError!void {
    const T = @TypeOf(value);
    const a = config.arena.allocator();
    for (comptime decoding.appendKeys(T)) |key| try config.setMerge(key, .append);
    const encoded = try decoding.encode(a, value);
    try config.mergeInto(a, &config.layers[@backingInt(Layer.default)], encoded);
    for (comptime decoding.secretKeys(T)) |key| try config.markSecret(key);
    try config.bindEnvs(T);
    try config.registerKeys(comptime structKeys(T));
    config.invalidate();
}

/// Sets `key_path` in the highest layer: it wins over every other source.
///
/// When the effective tree is already built, a scalar or list set this way is patched into
/// it rather than rebuilding it from every layer, which keeps a loop of `set` and `get`
/// cheap on a large configuration. With references, only the values that refer to the key,
/// directly or not, are expanded again.
pub fn set(config: *Config, key_path: []const u8, value: anytype) SetError!void {
    const a = config.arena.allocator();
    const encoded = try decoding.encode(a, value);
    try config.layers[@backingInt(Layer.override)].put(a, key_path, encoded);
    if (!try config.patchEffective(key_path, encoded)) config.invalidate();
}

/// Applies a `set` of `value` at `key_path` to the effective tree in place, when that is
/// sure to give what a rebuild would; returns false when the tree must be rebuilt.
fn patchEffective(config: *Config, key_path: []const u8, value: Value) Allocator.Error!bool {
    var effective = config.effective orelse return false;
    if (config.patches >= max_patches) return false;
    // Each of these makes the effective value depend on more than this one layer.
    if (config.case_insensitive or config.appends.count() > 0) return false;
    // Which reference a rebuild reports first depends on the order it expands them in.
    if (config.references and config.reference_problem != null) return false;
    // A table merges with what lies below it, which a rebuild does key by key.
    if (value == .table) return false;
    var it = path.iterate(key_path);
    while (it.next() catch return false) |segment| {
        // The override layer holds `a.0` as a key, but the effective tree may have an
        // array there; only a rebuild settles which wins.
        if (std.fmt.parseUnsigned(usize, segment.text, 10)) |_| return false else |_| {}
    }
    const c = config.cache.allocator();
    const copy = try value.clone(c);
    effective.put(c, key_path, copy) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // It crosses a scalar from a lower layer, which the override replaces.
        error.InvalidPath, error.NotATable, error.IndexOutOfRange => return false,
    };
    if (config.references and !try config.patchReferences(&effective, key_path, copy)) {
        return false;
    }
    config.effective = effective;
    // What was under `key_path` came from lower layers; now it all comes from here.
    var stale: std.ArrayList([]const u8) = .empty;
    for (config.origins.keys()) |origin_key| {
        const under = std.mem.startsWith(u8, origin_key, key_path) and
            (origin_key.len == key_path.len or origin_key[key_path.len] == '.');
        if (under) try stale.append(c, origin_key);
    }
    for (stale.items) |origin_key| _ = config.origins.orderedRemove(origin_key);
    try config.origins.put(c, try c.dupe(u8, key_path), .{ .layer = .override });
    config.patches += 1;
    return true;
}

/// With references on, after `value` is put at `key_path` in `effective`: puts it in the
/// unexpanded tree too, then expands again every value that refers to `key_path`, directly
/// or through other references. Returns false when the tree must be rebuilt instead.
fn patchReferences(
    config: *Config,
    effective: *Value,
    key_path: []const u8,
    value: Value,
) Allocator.Error!bool {
    const c = config.cache.allocator();
    var unexpanded = config.unexpanded orelse return false;
    unexpanded.put(c, key_path, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath, error.NotATable, error.IndexOutOfRange => return false,
    };
    config.unexpanded = unexpanded;
    const set_key = try normalizeKey(c, key_path) orelse return false;
    var pending: std.StringHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    try pending.put(c, set_key, {});
    try queue.append(c, set_key);
    while (queue.pop()) |key| {
        var it = config.dependents.iterator();
        while (it.next()) |entry| {
            // A reference to the key, to a key below it, or to a table holding it.
            const target = entry.key_ptr.*;
            if (!isUnder(target, key) and !isUnder(key, target)) continue;
            for (entry.value_ptr.items) |from| {
                const slot = try pending.getOrPut(c, from);
                if (!slot.found_existing) try queue.append(c, from);
            }
        }
    }
    // Back to the text as written, then expanded again.
    var stale = pending.keyIterator();
    while (stale.next()) |key| {
        const written = unexpanded.lookup(key.*) orelse continue;
        effective.put(c, key.*, try written.clone(c)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPath, error.NotATable, error.IndexOutOfRange => return false,
        };
    }
    var expander: Expander = .{
        .config = config,
        .root = effective,
        .arena = c,
        .pending = &pending,
    };
    stale = pending.keyIterator();
    while (stale.next()) |key| _ = try expander.expand(key.*);
    return config.reference_problem == null;
}

/// Whether `key` is `prefix` or below it.
fn isUnder(key: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, key, prefix) and
        (key.len == prefix.len or key[prefix.len] == '.');
}

/// `key` spelled as `leafPaths` spells it, quoting only where needed; null when it is not
/// a path.
fn normalizeKey(arena: Allocator, key: []const u8) Allocator.Error!?[]const u8 {
    const segments = path.split(arena, key) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return null,
    };
    var joined: []const u8 = "";
    for (segments) |segment| joined = try path.join(arena, joined, segment);
    return joined;
}

/// How many `set`s may patch the effective tree before one rebuilds it.
const max_patches = 32;

/// Removes `key_path` from the `override` layer. Returns whether it was there.
pub fn unset(config: *Config, key_path: []const u8) bool {
    config.invalidate();
    return config.layers[@backingInt(Layer.override)].remove(key_path);
}

fn putEncoded(config: *Config, layer: Layer, key_path: []const u8, value: anytype) SetError!void {
    const a = config.arena.allocator();
    const encoded = try decoding.encode(a, value);
    try config.layers[@backingInt(layer)].put(a, key_path, encoded);
    config.invalidate();
}

/// What loading a file or a source can fail with.
pub const LoadError = Io.Dir.ReadFileAllocError || error{
    UnknownFormat,
    SyntaxError,
    SecretNotFound,
    IncludeCycle,
    InvalidInclude,
    /// A `Source` failed; `diag` names it and the error.
    SourceFailed,
    /// An encrypted file, and no passphrase was given (`usePassphrase`).
    PassphraseRequired,
    /// An encrypted file the passphrase does not open, or one that was changed.
    WrongPassphrase,
    /// An encrypted file that is damaged, or of a kind this version cannot read.
    CorruptEncryption,
};

/// Reads `file_path` (relative to `dir`) and merges it into the `file` layer. The format
/// comes from the extension unless given. Parse errors are described in `diag`, with
/// `file` set, so `{f}` prints `path:line:column: message`.
pub fn loadFile(
    config: *Config,
    io: Io,
    dir: Io.Dir,
    file_path: []const u8,
    format: ?Format,
    diag: ?*Diagnostic,
) LoadError!void {
    var chain: std.ArrayList([]const u8) = .empty;
    defer chain.deinit(config.gpa);
    // A failure part way through an include tree loads none of it.
    const loaded = config.files.items.len;
    errdefer {
        for (config.files.items[loaded..]) |*file| file.arena.deinit();
        config.files.shrinkRetainingCapacity(loaded);
    }
    try config.loadIncluding(io, dir, file_path, format, diag, &chain, &config.files);
    try config.rebuildFiles();
}

/// Loads `file_path`, then each of its variants that exists, in order, each overriding
/// the files before it: for `app.toml` and `&.{ "production", "local" }`,
/// `app.production.toml` and then `app.local.toml`; for `.env`, `.env.production` and
/// `.env.local`, as dotenv tools and Rails environments do. Variants share the base
/// file's format. Returns how many variants were found; a missing base file is
/// `error.FileNotFound`, as for `loadFile`.
pub fn loadVariants(
    config: *Config,
    io: Io,
    dir: Io.Dir,
    file_path: []const u8,
    variants: []const []const u8,
    format: ?Format,
    diag: ?*Diagnostic,
) LoadError!usize {
    try config.loadFile(io, dir, file_path, format, diag);
    const named = format orelse Format.fromPath(file_path);
    var found: usize = 0;
    for (variants) |variant| {
        if (variant.len == 0) continue;
        const other = try variantPath(config.arena.allocator(), file_path, variant);
        dir.access(io, other, .{}) catch continue;
        try config.loadFile(io, dir, other, named, diag);
        found += 1;
    }
    return found;
}

/// `app.toml` with `local` is `app.local.toml`; `.env` with `local` is `.env.local`.
pub fn variantPath(
    arena: Allocator,
    file_path: []const u8,
    variant: []const u8,
) Allocator.Error![]const u8 {
    const base = std.fs.path.basename(file_path);
    if (std.mem.eql(u8, base, ".env") or std.mem.startsWith(u8, base, ".env.")) {
        return std.mem.concat(arena, u8, &.{ file_path, ".", variant });
    }
    const ext = std.fs.path.extension(base);
    const stem = file_path[0 .. file_path.len - ext.len];
    return std.mem.concat(arena, u8, &.{ stem, ".", variant, ext });
}

/// Appends `file_path` to `out` after the files it includes, which it overrides.
fn loadIncluding(
    config: *Config,
    io: Io,
    dir: Io.Dir,
    file_path: []const u8,
    format: ?Format,
    diag: ?*Diagnostic,
    chain: *std.ArrayList([]const u8),
    out: *std.ArrayList(FileSource),
) LoadError!void {
    for (chain.items, 0..) |pending, i| {
        if (!std.mem.eql(u8, pending, file_path)) continue;
        const a = config.arena.allocator();
        var cycle: std.ArrayList(u8) = .empty;
        for (chain.items[i..]) |link| {
            try cycle.appendSlice(a, link);
            try cycle.appendSlice(a, " -> ");
        }
        try cycle.appendSlice(a, file_path);
        if (diag) |d| d.* = .{ .key = config.include_key.?, .message = cycle.items };
        return error.IncludeCycle;
    }
    var file = try config.readFile(io, dir, file_path, format, diag);
    errdefer file.arena.deinit();
    file.included = chain.items.len > 0;
    if (config.include_key) |key| if (file.tree.table.fetchOrderedRemove(key)) |entry| {
        try chain.append(config.gpa, file.name);
        defer _ = chain.pop();
        const includes: []const Value = switch (entry.value) {
            .string => &.{entry.value},
            .array => |list| list.items,
            else => &.{.null},
        };
        for (includes) |include| {
            if (include != .string) {
                if (diag) |d| d.* = .{ .key = key, .message = "expected a file name or a list" };
                return error.InvalidInclude;
            }
            // Relative to the including file, as a C `#include "..."` is.
            const base = std.fs.path.dirname(file_path) orelse "";
            const a = file.arena.allocator();
            const target = if (std.fs.path.isAbsolute(include.string) or base.len == 0)
                include.string
            else
                try joinPath(a, base, include.string);
            try config.loadIncluding(io, dir, target, null, diag, chain, out);
        }
    };
    try out.append(config.gpa, file);
}

/// Turns on includes: a file's top-level `key` (a file name or a list of them) loads
/// those files first, relative to the including file, so the including file overrides
/// them. Each keeps its own provenance in `explain`; a cycle is `error.IncludeCycle`, with
/// the chain of files in `diag`. Off by default, since `include` may be a setting.
pub fn useIncludes(config: *Config, key: []const u8) Allocator.Error!void {
    config.include_key = try config.arena.allocator().dupe(u8, key);
}

/// Reads and parses one file into a new `FileSource`.
fn readFile(
    config: *Config,
    io: Io,
    dir: Io.Dir,
    file_path: []const u8,
    format: ?Format,
    diag: ?*Diagnostic,
) LoadError!FileSource {
    // An encrypted file names its format inside; `app.toml.enc` is decided on reading.
    const sealed = std.mem.endsWith(u8, file_path, ".enc");
    const named = format orelse Format.fromPath(file_path) orelse
        if (sealed) null else return error.UnknownFormat;
    var arena: std.heap.ArenaAllocator = .init(config.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    // Taken before reading, so a write racing the read shows up as a change later.
    const stamp = stampOf(io, dir, file_path);
    var source: []const u8 = try dir.readFileAlloc(io, file_path, a, .limited(max_file_size));
    var f = named orelse .toml;
    // A decrypted file's text, wiped once parsed, on every path.
    var plaintext: ?[]u8 = null;
    defer if (plaintext) |text| std.crypto.secureZero(u8, text);
    if (encrypted.isEncrypted(source)) {
        const passphrase = config.passphrase orelse return error.PassphraseRequired;
        const opened = encrypted.decrypt(a, io, source, passphrase) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.WrongPassphrase => error.WrongPassphrase,
                else => error.CorruptEncryption,
            };
        };
        plaintext = opened.plaintext;
        source = opened.plaintext;
        f = format orelse opened.format;
    } else if (named == null) {
        return error.UnknownFormat;
    }
    var tree = config.parseSource(a, source, f, diag) catch |err| {
        // The caller's path may be gone by the time the diagnostic is read.
        if (err == error.SyntaxError) if (diag) |d| {
            d.file = config.arena.allocator().dupe(u8, file_path) catch "";
        };
        return err;
    };
    if (plaintext != null) {
        // Parsers may borrow strings from the text, which is about to be wiped.
        tree = try tree.clone(a);
        source = "";
        // Everything in an encrypted file is treated as secret.
        var leaves: std.ArrayList([]const u8) = .empty;
        try tree.leafPaths(a, "", &leaves);
        for (leaves.items) |leaf| try config.markSecret(leaf);
    }
    try config.expandSecrets(io, a, &tree, diag);
    const name = try a.dupe(u8, file_path);
    // `arena` is copied last: what was allocated through `a` is in it only from here on.
    return .{
        .arena = arena,
        .name = name,
        .tree = tree,
        .format = f,
        .from = .{ .file = dir },
        .stamp = stamp,
        .text = source,
    };
}

fn stampOf(io: Io, dir: Io.Dir, file_path: []const u8) ?FileSource.Stamp {
    const stat = dir.statFile(io, file_path, .{}) catch return null;
    return .{ .size = stat.size, .mtime = stat.mtime.nanoseconds, .inode = stat.inode };
}

/// Whether a file `loadFile` or `loadDir` read (an included one too) has changed on disk
/// since: its size, modification time, or inode differs, or it is gone. Cheap: one `stat`
/// per file, nothing read. For a watch loop without threads, call it on a timer and
/// `reload` when it says so. Text from `loadSource` and `loadReader` never changes, and a
/// `Source` cannot be checked this way, so neither counts.
pub fn changed(config: *const Config, io: Io) bool {
    for (config.files.items) |file| switch (file.from) {
        .file => |dir| {
            const now = stampOf(io, dir, file.name) orelse return true;
            const then = file.stamp orelse return true;
            if (!std.meta.eql(now, then)) return true;
        },
        .text, .source => {},
    };
    return false;
}

/// Lets `loadFile` open files encrypted with `encrypted.encrypt` (`snek cfg encrypt`).
/// Their keys are all marked secret, so `write` redacts them. The decrypted text is wiped
/// once parsed and not kept, so `locateDiagnostic` does not point into such a file (nor
/// quote it); the values themselves stay in memory as any configuration does.
/// `passphrase` is borrowed: keep it alive, ideally in memory from `platform.secure`, as
/// long as files may load.
pub fn usePassphrase(config: *Config, passphrase: []const u8) void {
    config.passphrase = passphrase;
}

/// Reads configuration in `format` from `reader` and merges it into the `file` layer,
/// attributing its keys to `name`. JSON is parsed as it streams in, and YAML a top-level
/// entry at a time, without holding the whole text; other formats are read whole first.
/// `reload` keeps what this read.
pub fn loadReader(
    config: *Config,
    name: []const u8,
    reader: *Io.Reader,
    format: Format,
    diag: ?*Diagnostic,
) (error{ SyntaxError, ReadFailed, StreamTooLong } || Allocator.Error)!void {
    var arena: std.heap.ArenaAllocator = .init(config.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const tree = if (format == .json or format == .yaml) blk: {
        const parsed = if (format == .json)
            try json.parseReader(a, reader, diag)
        else
            try yaml.parseReader(a, config.gpa, reader, max_file_size, diag);
        if (parsed != .table) {
            const message = "a configuration file must hold a table at the top level";
            Diagnostic.report(diag, "", 0, message);
            return error.SyntaxError;
        }
        break :blk parsed;
    } else blk: {
        const source = try reader.allocRemaining(a, .limited(max_file_size));
        break :blk try config.parseSource(a, source, format, diag);
    };
    const owned_name = try a.dupe(u8, name);
    try config.files.append(config.gpa, .{
        .arena = arena,
        .name = owned_name,
        .tree = tree,
        .format = format,
        .from = .text,
    });
    try config.rebuildFiles();
}

/// Merges what `source` loads into the `file` layer, above the files loaded before it.
/// Secret references in it are resolved, as in a file.
pub fn loadFrom(config: *Config, io: Io, source: Source, diag: ?*Diagnostic) LoadError!void {
    var file = try config.readSource(io, source, diag);
    errdefer file.arena.deinit();
    try config.files.append(config.gpa, file);
    try config.rebuildFiles();
}

fn readSource(config: *Config, io: Io, source: Source, diag: ?*Diagnostic) LoadError!FileSource {
    var arena: std.heap.ArenaAllocator = .init(config.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var local: Diagnostic = .{};
    const loaded = source.load(source.context, io, a, &local) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (diag) |d| d.* = .{
            .key = try config.arena.allocator().dupe(u8, source.name),
            .message = try std.fmt.allocPrint(config.arena.allocator(), "{s}{s}{s}", .{
                @errorName(err),
                if (local.message.len > 0) ": " else "",
                local.message,
            }),
        };
        return error.SourceFailed;
    };
    if (loaded != .table) {
        if (diag) |d| d.* = .{
            .key = try config.arena.allocator().dupe(u8, source.name),
            .message = "a configuration source must load a table",
        };
        return error.SourceFailed;
    }
    var tree = loaded;
    try config.expandSecrets(io, a, &tree, diag);
    const name = try a.dupe(u8, source.name);
    return .{
        .arena = arena,
        .name = name,
        .tree = tree,
        .format = .json,
        .from = .{ .source = source },
    };
}

/// Parses `source` and merges it into the `file` layer, attributing its keys to `name`.
/// A dotenv source may expand variables from the environment given to `useEnv`.
pub fn loadSource(
    config: *Config,
    name: []const u8,
    source: []const u8,
    format: Format,
    diag: ?*Diagnostic,
) (error{SyntaxError} || Allocator.Error)!void {
    var arena: std.heap.ArenaAllocator = .init(config.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const tree = try config.parseSource(a, source, format, diag);
    const owned_name = try a.dupe(u8, name);
    const text = try a.dupe(u8, source);
    try config.files.append(config.gpa, .{
        .arena = arena,
        .name = owned_name,
        .tree = tree,
        .format = format,
        .from = .text,
        .text = text,
    });
    try config.rebuildFiles();
}

fn parseSource(
    config: *Config,
    a: Allocator,
    source: []const u8,
    format: Format,
    diag: ?*Diagnostic,
) (error{SyntaxError} || Allocator.Error)!Value {
    const parsed = switch (format) {
        .dotenv => dotenv.parseWith(a, source, diag, .{ .environ = config.environ }),
        else => format.parse(a, source, diag),
    };
    const tree = parsed catch |err| {
        // A message the parser allocated (ZON's) would go with the source's arena.
        if (diag) |d| d.message = try config.arena.allocator().dupe(u8, d.message);
        return err;
    };
    if (tree != .table) {
        Diagnostic.report(diag, "", 0, "a configuration file must hold a table at the top level");
        return error.SyntaxError;
    }
    return tree;
}

/// Rebuilds the `file` layer and its sources from `files`, in load order.
fn rebuildFiles(config: *Config) Allocator.Error!void {
    _ = config.file_arena.reset(.retain_capacity);
    const a = config.file_arena.allocator();
    const layer = @backingInt(Layer.file);
    config.layers[layer] = .empty_table;
    config.sources[layer] = .empty;
    for (config.files.items) |file| {
        try config.mergeInto(a, &config.layers[layer], file.tree);
        var leaves: std.ArrayList([]const u8) = .empty;
        try file.tree.leafPaths(a, "", &leaves);
        for (leaves.items) |leaf| try config.sources[layer].put(a, leaf, file.name);
    }
    config.invalidate();
}

/// Loads every file in the directory `sub_path` of `dir` whose extension names a format,
/// in name order, as one `loadFile` each: the `conf.d` pattern. Files starting with `.`,
/// directories, and other extensions are skipped. Returns how many files were loaded; a
/// missing directory is `error.FileNotFound`.
pub fn loadDir(
    config: *Config,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    diag: ?*Diagnostic,
) (LoadError || Io.Dir.OpenError || Io.Dir.Iterator.Error)!usize {
    var opened = try dir.openDir(io, sub_path, .{ .iterate = true });
    defer opened.close(io);
    const scratch = config.cache.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var it = opened.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or entry.name.len == 0 or entry.name[0] == '.') continue;
        if (Format.fromPath(entry.name) == null) continue;
        try names.append(scratch, try joinPath(scratch, sub_path, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| try config.loadFile(io, dir, name, null, diag);
    return names.items.len;
}

/// Reads every file `loadFile` and `loadDir` loaded again, following their includes as
/// they are now, and returns what changed in the effective configuration, sorted by key, in
/// `arena`. Sources given to `loadSource` keep their contents. If any file fails to read or
/// parse, nothing changes and the error is returned. Watching for changes stays the
/// caller's: call this from a timer, a signal handler's flag, or a file-change
/// notification.
pub fn reload(
    config: *Config,
    io: Io,
    arena: Allocator,
    diag: ?*Diagnostic,
) (LoadError || Allocator.Error)![]const differ.Change {
    const before = try (try config.resolve()).clone(arena);
    // Built beside the loaded files, then swapped in; given text moves across unread.
    var fresh: std.ArrayList(FileSource) = .empty;
    defer fresh.deinit(config.gpa);
    errdefer for (fresh.items) |*file| if (file.from != .text) file.arena.deinit();
    var chain: std.ArrayList([]const u8) = .empty;
    defer chain.deinit(config.gpa);
    for (config.files.items) |file| switch (file.from) {
        .text => try fresh.append(config.gpa, file),
        .file => |dir| if (!file.included) {
            try config.loadIncluding(io, dir, file.name, file.format, diag, &chain, &fresh);
        },
        .source => |source| {
            var again = try config.readSource(io, source, diag);
            errdefer again.arena.deinit();
            try fresh.append(config.gpa, again);
        },
    };
    std.mem.swap(std.ArrayList(FileSource), &config.files, &fresh);
    for (fresh.items) |*file| if (file.from != .text) file.arena.deinit();
    fresh.clearRetainingCapacity();
    try config.rebuildFiles();
    const after = try (try config.resolve()).clone(arena);
    return differ.diff(arena, before, after);
}

/// Where `findFile` looks.
pub const FindOptions = struct {
    /// The file name without extension.
    name: []const u8,
    /// Directories to search, in order. A leading `$VAR` or `~` is expanded from the
    /// environment given to `useEnv`; a directory whose variable is unset is skipped.
    dirs: []const []const u8 = &.{"."},
    /// Formats to try in each directory, in order.
    formats: []const Format = &.{ .toml, .yaml, .json, .zon, .dotenv, .jsonc, .ini },
    /// First look in the working directory and each directory above it, stopping after
    /// `$HOME` or the root, as git finds `.git` and cosmiconfig finds `.apprc`; then in
    /// `dirs`.
    upward: bool = false,
    /// Where `upward` starts, instead of the working directory.
    start: ?[]const u8 = null,
};

/// Returns the first existing `<dir>/<name><ext>`, or null. The path lives until `deinit`.
pub fn findFile(config: *Config, io: Io, options: FindOptions) Allocator.Error!?[]const u8 {
    if (options.upward) upward: {
        const a = config.arena.allocator();
        const start = Io.Dir.cwd().realPathFileAlloc(io, options.start orelse ".", a) catch
            break :upward;
        const home = if (config.environ) |environ| environ.get("HOME") else null;
        var dir: []const u8 = start;
        while (true) {
            if (try config.findIn(io, dir, options)) |found| return found;
            if (home) |h| if (std.mem.eql(u8, std.mem.trimEnd(u8, h, "/"), dir)) break;
            dir = std.fs.path.dirname(dir) orelse break;
        }
    }
    for (options.dirs) |dir_spec| {
        const dir = try config.expandDir(dir_spec) orelse continue;
        if (try config.findIn(io, dir, options)) |found| return found;
    }
    return null;
}

fn findIn(
    config: *Config,
    io: Io,
    dir: []const u8,
    options: FindOptions,
) Allocator.Error!?[]const u8 {
    const a = config.arena.allocator();
    for (options.formats) |format| {
        for (format.extensions()) |ext| {
            const name = try std.mem.concat(a, u8, &.{ options.name, ext });
            const candidate = try joinPath(a, dir, name);
            Io.Dir.cwd().access(io, candidate, .{}) catch continue;
            return candidate;
        }
    }
    return null;
}

fn expandDir(config: *Config, dir: []const u8) Allocator.Error!?[]const u8 {
    const is_home = std.mem.eql(u8, dir, "~") or std.mem.startsWith(u8, dir, "~/");
    if (dir.len == 0 or (dir[0] != '$' and !is_home)) return dir;
    const environ = config.environ orelse return null;
    const name_end = if (is_home) 1 else std.mem.indexOfAny(u8, dir, "/\\") orelse dir.len;
    const name = if (is_home) "HOME" else dir[1..name_end];
    const value = environ.get(name) orelse return null;
    if (value.len == 0) return null;
    return try std.mem.concat(config.arena.allocator(), u8, &.{ value, dir[name_end..] });
}

/// Where `loadAppFile` looks.
pub const AppFileOptions = struct {
    /// The file the user named, with a flag such as `--config`; used as it is.
    path: ?[]const u8 = null,
    /// The environment variable naming the file when `path` is null (`"REPOS_CONFIG"`),
    /// read from the environment given to `useEnv`.
    env: ?[]const u8 = null,
    /// The file's name in the application's configuration directory.
    name: []const u8 = "config.toml",
    /// The format, when the extension does not say it.
    format: ?Format = null,
};

/// The file `loadAppFile` chose.
pub const AppFile = struct {
    /// Where the file is, or would be: where to write one when it was not found. Lives
    /// until `deinit`.
    path: []const u8,
    /// The file exists, and was loaded.
    found: bool,
};

/// What `loadAppFile` can fail with.
pub const AppFileError = LoadError || error{
    /// No file was named, and there is no configuration directory: no environment from
    /// `useEnv`, or no home directory in it.
    NoConfigDir,
};

/// Loads the application's own configuration file, or none: `options.path` when given,
/// else the file the variable `options.env` names, else `options.name` in the user's
/// configuration directory for `app`, as `platform.dirs` places it (`$XDG_CONFIG_HOME/<app>`
/// or `~/.config/<app>`; `~/Library/Application Support/<app>` on macOS;
/// `%APPDATA%\<app>` on Windows). A file that does not exist is not an error: `found` is
/// false, and `path` says where one would go. Call `useEnv` first.
///
/// ```zig
/// config.useEnv(environ);
/// const options: cfg.Config.AppFileOptions = .{ .path = flags.config, .env = "REPOS_CONFIG" };
/// const file = try config.loadAppFile(io, "repos", options, &diag);
/// if (!file.found) ... // first run: offer to write file.path
/// ```
pub fn loadAppFile(
    config: *Config,
    io: Io,
    app: []const u8,
    options: AppFileOptions,
    diag: ?*Diagnostic,
) AppFileError!AppFile {
    const a = config.arena.allocator();
    const named = options.path orelse if (options.env) |name| named: {
        const environ = config.environ orelse break :named null;
        break :named if (environ.get(name)) |value| if (value.len > 0) value else null else null;
    } else null;
    const file_path = if (named) |given| try a.dupe(u8, given) else path: {
        const environ = config.environ orelse return error.NoConfigDir;
        const os = @import("builtin").os.tag;
        const dir = try appConfigDir(a, environ, os, app) orelse return error.NoConfigDir;
        break :path try std.mem.concat(a, u8, &.{ dir, separator(os), options.name });
    };
    config.loadFile(io, .cwd(), file_path, options.format, diag) catch |err| switch (err) {
        error.FileNotFound => return .{ .path = file_path, .found = false },
        else => |e| return e,
    };
    return .{ .path = file_path, .found = true };
}

fn separator(os: std.Target.Os.Tag) []const u8 {
    return if (os == .windows) "\\" else "/";
}

/// The user's configuration directory for `app` on `os`, in `a`; null without a home.
/// Follows `platform.dirs`, which `cfg` does not import.
fn appConfigDir(
    a: Allocator,
    environ: *const std.process.Environ.Map,
    os: std.Target.Os.Tag,
    app: []const u8,
) Allocator.Error!?[]const u8 {
    const sep = separator(os);
    if (os == .windows) {
        if (absolute(os, environ.get("APPDATA"))) |dir| return try std.mem.concat(a, u8, &.{
            dir, sep, app,
        });
        const home = absolute(os, environ.get("USERPROFILE")) orelse return null;
        return try std.mem.concat(a, u8, &.{ home, "\\AppData\\Roaming\\", app });
    }
    if (absolute(os, environ.get("XDG_CONFIG_HOME"))) |dir| {
        return try std.mem.concat(a, u8, &.{ dir, sep, app });
    }
    const home = absolute(os, environ.get("HOME")) orelse return null;
    const middle = if (os.isDarwin()) "/Library/Application Support/" else "/.config/";
    return try std.mem.concat(a, u8, &.{ home, middle, app });
}

/// `value` when it is an absolute path on `os`.
fn absolute(os: std.Target.Os.Tag, value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    if (os != .windows) return if (v.len > 0 and v[0] == '/') v else null;
    const drive = v.len >= 3 and std.ascii.isAlphabetic(v[0]) and v[1] == ':' and
        (v[2] == '\\' or v[2] == '/');
    const unc = v.len >= 2 and (v[0] == '\\' or v[0] == '/') and (v[1] == '\\' or v[1] == '/');
    return if (drive or unc) v else null;
}

/// Activates a profile: the table at `profiles.<name>` in the file layer is merged above the
/// files. A profile that does not exist is not an error; `profileNames` lists those that do.
pub fn useProfile(config: *Config, name: ?[]const u8) Allocator.Error!void {
    config.profile = if (name) |n| try config.arena.allocator().dupe(u8, n) else null;
    config.invalidate();
}

/// The profiles defined in the loaded files.
pub fn profileNames(config: *Config) []const []const u8 {
    const files = config.layers[@backingInt(Layer.file)];
    const profiles = files.table.get(config.profiles_key) orelse return &.{};
    if (profiles != .table) return &.{};
    return profiles.table.keys();
}

/// Makes environment variables a source. Values are read when the effective tree is built,
/// so later changes to `environ` are seen. `environ` must outlive the `Config`.
pub fn useEnv(config: *Config, environ: *const std.process.Environ.Map) void {
    config.environ = environ;
    config.invalidate();
}

/// Looks up every key as `<PREFIX>_<KEY>` (see `path.toEnvName`): with prefix `APP`, the
/// key `server.port` is read from `APP_SERVER_PORT`. An empty prefix reads `SERVER_PORT`.
pub fn automaticEnv(config: *Config, prefix: []const u8) Allocator.Error!void {
    config.automatic_env = true;
    config.env_prefix = try config.arena.allocator().dupe(u8, prefix);
    config.invalidate();
}

/// Reads `key_path` from the environment variable `env_name`. Takes precedence over the
/// automatic name.
pub fn bindEnv(config: *Config, key_path: []const u8, env_name: []const u8) Allocator.Error!void {
    const a = config.arena.allocator();
    try config.env_bindings.put(a, try a.dupe(u8, key_path), try a.dupe(u8, env_name));
    config.invalidate();
}

/// Binds every environment variable `T.meta` names with `.env`, at any depth: with
/// `.port = .{ .env = "PORT" }`, the key `port` is read from `$PORT`, as `bindEnv` does.
/// The same option names a `cli` flag's variable, so one struct serves both. `setDefaults`
/// and `decode` call this.
pub fn bindEnvs(config: *Config, comptime T: type) Allocator.Error!void {
    for (comptime decoding.envBindings(T)) |binding| {
        if (config.env_bindings.contains(binding.key)) continue; // `bindEnv` wins.
        try config.bindEnv(binding.key, binding.env);
    }
}

/// Makes `key_paths` candidates for environment lookup even when no layer sets them, and
/// keys `bindFlags` binds. `setDefaults` and `decode` register their struct's keys.
pub fn registerKeys(config: *Config, key_paths: []const []const u8) Allocator.Error!void {
    const a = config.arena.allocator();
    for (key_paths) |key| {
        const gop = try config.known_keys.getOrPut(a, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, key);
            config.invalidate();
        }
    }
}

/// How `bindFlags` turns flag names into keys.
pub const BindOptions = struct {
    /// Prepended to every flag name, with a `.`.
    prefix: []const u8 = "",
    /// Map `dry-run` to the key `dry_run`.
    snake_case: bool = true,
};

/// Loads command-line flags into the `flag` layer. `records` is any slice whose elements
/// have `name` and `value` text fields, such as `cli.Context.changedFlags()`. A name that
/// occurs more than once becomes an array. Values are typed by `cfg.infer`.
///
/// A record's key is its optional `key` field when set (a `cli` flag's `.key` meta, such
/// as `"fetch.concurrency"`), else its name. Once the configuration knows its keys
/// (`setDefaults`, `decode`, or `registerKeys`), a record whose key is none of them is
/// left out unless it names its `key`: `--config` or `--verbose` do not become settings.
pub fn bindFlags(config: *Config, records: anytype, options: BindOptions) SetError!void {
    const a = config.arena.allocator();
    var flags: Value = .empty_table;
    const filter = config.known_keys.count() > 0;
    for (records) |record| {
        const named: ?[]const u8 = if (@hasField(@TypeOf(record), "key")) record.key else null;
        const key = if (named) |k|
            try a.dupe(u8, k)
        else
            try flagKey(a, options, record.name);
        if (filter and named == null and !config.isKnown(key)) continue;
        const value = scalar.infer(try a.dupe(u8, record.value));
        if (flags.lookup(key)) |existing| {
            var array: Array = if (existing == .array) existing.array else .empty;
            if (existing != .array) try array.append(a, existing);
            try array.append(a, value);
            try flags.put(a, key, .{ .array = array });
        } else {
            try flags.put(a, key, value);
        }
        try config.sources[@backingInt(Layer.flag)].put(
            a,
            key,
            try std.mem.concat(a, u8, &.{ "--", record.name }),
        );
    }
    try config.layers[@backingInt(Layer.flag)].merge(a, flags);
    config.invalidate();
}

/// Sets one flag-layer value from text.
pub fn setFlag(config: *Config, key_path: []const u8, text: []const u8) SetError!void {
    const Record = struct { name: []const u8, value: []const u8, key: ?[]const u8 };
    const record = [_]Record{.{ .name = key_path, .value = text, .key = key_path }};
    try config.bindFlags(&record, .{ .snake_case = false });
}

/// Whether `key` is a registered key or the table above some.
fn isKnown(config: *const Config, key: []const u8) bool {
    for (config.known_keys.keys()) |known| if (isUnder(known, key)) return true;
    return false;
}

fn flagKey(a: Allocator, options: BindOptions, name: []const u8) Allocator.Error![]const u8 {
    const key = try a.dupe(u8, name);
    if (options.snake_case) std.mem.replaceScalar(u8, key, '-', '_');
    if (options.prefix.len == 0) return key;
    return std.mem.concat(a, u8, &.{ options.prefix, ".", key });
}

/// How a list at a key combines with a list from a higher source.
pub const Merge = enum {
    /// The higher source's list replaces the lower one, as any value does.
    replace,
    /// The lists are concatenated, lower first: plugins from every file, say.
    append,
};

/// Sets how the lists at `key_path` combine across files and layers. A struct's `meta` can
/// say the same (`.plugins = .{ .merge = .append }`), applied by `setDefaults`.
pub fn setMerge(config: *Config, key_path: []const u8, strategy: Merge) Allocator.Error!void {
    const a = config.arena.allocator();
    switch (strategy) {
        .append => try config.appends.put(a, try a.dupe(u8, key_path), {}),
        .replace => _ = config.appends.orderedRemove(key_path),
    }
    try config.rebuildFiles();
}

/// `dst.merge(src)`, except that the lists at `append` keys are concatenated.
fn mergeInto(config: *Config, a: Allocator, dst: *Value, src: Value) Allocator.Error!void {
    var combined: std.ArrayList(struct { []const u8, Array }) = .empty;
    for (config.appends.keys()) |key| {
        const lower = dst.lookup(key) orelse continue;
        const higher = src.lookup(key) orelse continue;
        if (lower != .array or higher != .array) continue;
        var list: Array = .empty;
        try list.appendSlice(a, lower.array.items);
        for (higher.array.items) |item| try list.append(a, try item.clone(a));
        try combined.append(a, .{ key, list });
    }
    try dst.merge(a, src);
    for (combined.items) |entry| {
        dst.put(a, entry[0], .{ .array = entry[1] }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // `lookup` found the key in `dst` before the merge, and merging keeps tables.
            error.InvalidPath, error.NotATable, error.IndexOutOfRange => unreachable,
        };
    }
}

/// Makes keys compare without regard to ASCII case, as viper does: `Server.Port` in a file,
/// `server.port` in a call, and `SERVER_PORT` from the environment are one key. The
/// effective tree's keys are all lower-cased, so they no longer round-trip as written; for
/// that reason it is off by default. Sources keep their case in `write(.{ .layer })`.
pub fn ignoreKeyCase(config: *Config) void {
    config.case_insensitive = true;
    config.invalidate();
}

/// `key_path` as the effective tree spells it: lower-cased when keys ignore case. In the
/// cache arena, so call it after `resolve`.
fn foldKey(config: *Config, key_path: []const u8) Allocator.Error![]const u8 {
    if (!config.case_insensitive) return key_path;
    return std.ascii.allocLowerString(config.cache.allocator(), key_path);
}

/// `tree` with every table key lower-cased when keys ignore case; keys that then collide
/// merge, the later winning.
fn foldTree(config: *Config, a: Allocator, tree: Value) Allocator.Error!Value {
    if (!config.case_insensitive) return tree;
    switch (tree) {
        .table => |t| {
            var out: Value = .empty_table;
            var it = t.iterator();
            while (it.next()) |entry| {
                var one: Value = .empty_table;
                const key = try std.ascii.allocLowerString(a, entry.key_ptr.*);
                try one.table.put(a, key, try config.foldTree(a, entry.value_ptr.*));
                try out.merge(a, one);
            }
            return out;
        },
        .array => |items| {
            var out: Array = .empty;
            for (items.items) |item| try out.append(a, try config.foldTree(a, item));
            return .{ .array = out };
        },
        else => return tree,
    }
}

/// Marks `key_path` as secret: `write` redacts it.
pub fn markSecret(config: *Config, key_path: []const u8) Allocator.Error!void {
    const a = config.arena.allocator();
    try config.secrets.put(a, try a.dupe(u8, key_path), {});
}

/// Whether `key_path` was marked secret, by `markSecret` or a struct's `meta`.
pub fn isSecret(config: *const Config, key_path: []const u8) bool {
    if (config.secrets.contains(key_path)) return true;
    if (!config.case_insensitive) return false;
    for (config.secrets.keys()) |secret| {
        if (std.ascii.eqlIgnoreCase(secret, key_path)) return true;
    }
    return false;
}

// -- The effective tree ----------------------------------------------------------------

/// The effective tree, rebuilt if anything changed since the last call.
pub fn resolve(config: *Config) Allocator.Error!Value {
    if (config.effective) |value| return value;
    _ = config.cache.reset(.retain_capacity);
    config.patches = 0;
    config.origins = .empty;
    config.derived_profile = .empty_table;
    config.derived_env = .empty_table;
    const a = config.cache.allocator();

    var result: Value = .empty_table;
    try config.overlay(&result, .default);
    try config.overlay(&result, .file);
    if (config.profile) |name| {
        const files = config.layers[@backingInt(Layer.file)];
        if (files.table.get(config.profiles_key)) |profiles| {
            if (profiles == .table) {
                if (profiles.table.get(name)) |selected| {
                    const folded = try config.foldTree(a, selected);
                    try config.mergeInto(a, &result, folded);
                    config.derived_profile = folded;
                }
                try config.recordProfile(name, selected: {
                    break :selected profiles.table.get(name) orelse Value.empty_table;
                });
            }
        }
    }
    _ = result.remove(config.profiles_key);
    try config.overlayEnv(&result);
    try config.overlay(&result, .flag);
    try config.overlay(&result, .override);
    config.reference_problem = null;
    config.unexpanded = null;
    config.dependents = .empty;
    if (config.references) {
        config.unexpanded = try result.clone(a);
        try config.expandReferences(&result);
    }
    config.effective = result;
    return result;
}

// -- Secret references -----------------------------------------------------------------

/// Looks secrets up for `${secret:<scheme>:<name>}` (see `addSecretProvider`).
pub const SecretProvider = struct {
    context: ?*anyopaque = null,
    /// The secret called `name`, in `arena`; null when there is none.
    fetch: *const fn (
        context: ?*anyopaque,
        io: Io,
        arena: Allocator,
        name: []const u8,
    ) anyerror!?[]const u8,
};

/// Makes `${secret:<scheme>:<name>}` in a loaded file ask `provider` for `name`: a vault,
/// a keychain, a cloud secret store. Built in: `env` (an environment variable, from
/// `useEnv`) and `file` (a file's contents without the final line break, as Docker and
/// Kubernetes mount secrets). Secrets are looked up when a file is loaded, and every key
/// holding one is marked secret, so `write` redacts it.
pub fn addSecretProvider(
    config: *Config,
    scheme: []const u8,
    provider: SecretProvider,
) Allocator.Error!void {
    const a = config.arena.allocator();
    try config.secret_providers.put(a, try a.dupe(u8, scheme), provider);
}

/// Replaces every `${secret:...}` in the string leaves of `tree`, and marks those keys
/// secret.
fn expandSecrets(
    config: *Config,
    io: Io,
    a: Allocator,
    tree: *Value,
    diag: ?*Diagnostic,
) (error{SecretNotFound} || Allocator.Error)!void {
    var leaves: std.ArrayList([]const u8) = .empty;
    try tree.leafPaths(a, "", &leaves);
    for (leaves.items) |key| {
        const value = tree.lookup(key).?;
        if (value != .string or std.mem.indexOf(u8, value.string, "${") == null) continue;
        const text = value.string;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        var secret = false;
        var expanded = false;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, "${")) |start| {
            const close = std.mem.indexOfScalarPos(u8, text, start, '}') orelse break;
            from = close + 1;
            const reference = text[start + 2 .. close];
            const colon = std.mem.indexOfScalar(u8, reference, ':') orelse continue;
            const head = reference[0..colon];
            const rest = reference[colon + 1 ..];
            const is_secret = std.mem.eql(u8, head, "secret");
            const resolver = config.resolvers.get(head);
            if (!is_secret and resolver == null) continue; // A reference, or plain text.
            try out.appendSlice(a, text[i..start]);
            const resolved = (if (is_secret) secret: {
                const split = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
                const name = if (split < rest.len) rest[split + 1 ..] else "";
                break :secret config.fetchSecret(io, a, rest[0..split], name);
            } else resolver.?.fetch(resolver.?.context, io, a, rest)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            } orelse {
                if (diag) |d| d.* = .{
                    .key = try config.arena.allocator().dupe(u8, key),
                    .message = try std.fmt.allocPrint(
                        config.arena.allocator(),
                        "{s} {s}",
                        .{
                            if (is_secret) "no secret" else "nothing for",
                            text[start .. close + 1],
                        },
                    ),
                };
                return error.SecretNotFound;
            };
            try out.appendSlice(a, resolved);
            secret = secret or is_secret;
            expanded = true;
            i = close + 1;
        }
        if (!expanded) continue;
        try out.appendSlice(a, text[i..]);
        tree.put(a, key, .{ .string = out.items }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // `lookup` found the key, so every segment on the way is a container.
            error.InvalidPath, error.NotATable, error.IndexOutOfRange => unreachable,
        };
        if (secret) try config.markSecret(key);
    }
}

/// Makes `${name:argument}` in a loaded file ask `resolver` for `argument`, as
/// `addSecretProvider` does for secrets, but without marking the key secret: `${env:HOME}`,
/// `${now:%Y}`, `${git:branch}`. Resolved when a file is loaded; an argument the resolver
/// has nothing for fails the load (`error.SecretNotFound`, with `diag`). A `${...}` naming
/// no resolver is left alone, for `useReferences`.
pub fn addResolver(
    config: *Config,
    name: []const u8,
    resolver: SecretProvider,
) Allocator.Error!void {
    const a = config.arena.allocator();
    try config.resolvers.put(a, try a.dupe(u8, name), resolver);
}

fn fetchSecret(
    config: *Config,
    io: Io,
    a: Allocator,
    scheme: []const u8,
    name: []const u8,
) anyerror!?[]const u8 {
    if (config.secret_providers.get(scheme)) |provider| {
        return provider.fetch(provider.context, io, a, name);
    }
    if (std.mem.eql(u8, scheme, "env")) {
        const environ = config.environ orelse return null;
        return environ.get(name);
    }
    if (std.mem.eql(u8, scheme, "file")) {
        const limit: Io.Limit = .limited(max_file_size);
        const contents = Io.Dir.cwd().readFileAlloc(io, name, a, limit) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| return e,
        };
        return std.mem.trimEnd(u8, contents, "\r\n");
    }
    return null;
}

// -- References ------------------------------------------------------------------------

/// A reference that could not be expanded: it is left as written.
pub const ReferenceProblem = struct {
    /// The key whose value holds the reference.
    key: []const u8,
    /// What is wrong: `unknown key "x"`, or the cycle, `a -> b -> a`.
    message: []const u8,
};

/// Turns on `${key}` references inside string values, resolved on the effective tree after
/// every layer is applied: `url = "http://${server.host}:${server.port}"`. `$${` writes a
/// literal `${`. A reference to a missing key or one in a cycle stays as written; see
/// `checkReferences`. Off by default, since a value may hold `${` by chance.
pub fn useReferences(config: *Config) void {
    config.references = true;
    config.invalidate();
}

/// `error.BadReference`, with `diag` naming the key and the problem, when a reference
/// could not be expanded: a missing key or a cycle (`a -> b -> a`).
pub fn checkReferences(
    config: *Config,
    diag: ?*Diagnostic,
) (error{BadReference} || Allocator.Error)!void {
    _ = try config.resolve();
    const problem = config.reference_problem orelse return;
    if (diag) |d| d.* = .{ .key = problem.key, .message = problem.message };
    return error.BadReference;
}

fn expandReferences(config: *Config, result: *Value) Allocator.Error!void {
    const a = config.cache.allocator();
    var leaves: std.ArrayList([]const u8) = .empty;
    try result.leafPaths(a, "", &leaves);
    var expander: Expander = .{ .config = config, .root = result, .arena = a };
    for (leaves.items) |leaf| _ = try expander.expand(leaf);
}

/// Expands references leaf by leaf, depth first, remembering finished leaves and the
/// chain being expanded, which detects cycles.
const Expander = struct {
    config: *Config,
    root: *Value,
    arena: Allocator,
    done: std.StringHashMapUnmanaged(void) = .empty,
    chain: std.ArrayList([]const u8) = .empty,
    /// When set, only these keys need expanding; every other value already is.
    pending: ?*const std.StringHashMapUnmanaged(void) = null,

    /// Expands the value at `key` in place; returns whether that succeeded.
    fn expand(e: *Expander, key: []const u8) Allocator.Error!bool {
        if (e.done.contains(key)) return true;
        if (e.pending) |pending| if (!pending.contains(key)) return true;
        for (e.chain.items, 0..) |pending, i| {
            if (!std.mem.eql(u8, pending, key)) continue;
            var cycle: std.ArrayList(u8) = .empty;
            for (e.chain.items[i..]) |link| {
                try cycle.appendSlice(e.arena, link);
                try cycle.appendSlice(e.arena, " -> ");
            }
            try cycle.appendSlice(e.arena, key);
            try e.report(e.chain.items[e.chain.items.len - 1], try std.fmt.allocPrint(
                e.arena,
                "reference cycle: {s}",
                .{cycle.items},
            ));
            return false;
        }
        const value = e.root.lookup(key) orelse return true;
        if (value != .string or std.mem.indexOf(u8, value.string, "${") == null) {
            try e.done.put(e.arena, key, {});
            return true;
        }
        try e.chain.append(e.arena, key);
        defer _ = e.chain.pop();
        const text = value.string;
        var out: std.ArrayList(u8) = .empty;
        var ok = true;
        var i: usize = 0;
        while (i < text.len) {
            if (std.mem.startsWith(u8, text[i..], "$${")) {
                try out.appendSlice(e.arena, "${");
                i += 3;
                continue;
            }
            if (!std.mem.startsWith(u8, text[i..], "${")) {
                try out.append(e.arena, text[i]);
                i += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, text, i + 2, '}') orelse {
                try out.appendSlice(e.arena, text[i..]);
                break;
            };
            const target = try e.config.foldKey(text[i + 2 .. close]);
            const replacement = try e.lookup(key, target);
            if (replacement) |r| {
                try out.appendSlice(e.arena, r);
            } else {
                ok = false;
                try out.appendSlice(e.arena, text[i .. close + 1]);
            }
            i = close + 1;
        }
        e.root.put(e.arena, key, .{ .string = out.items }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // `lookup` found the key, so every segment on the way is a container.
            error.InvalidPath, error.NotATable, error.IndexOutOfRange => unreachable,
        };
        try e.done.put(e.arena, key, {});
        return ok;
    }

    /// The text `target` expands to, for a reference in `from`; null when it cannot.
    fn lookup(e: *Expander, from: []const u8, target: []const u8) Allocator.Error!?[]const u8 {
        // Recorded even when `target` is missing: setting it later changes `from`.
        if (try normalizeKey(e.arena, target)) |name| {
            const slot = try e.config.dependents.getOrPut(e.arena, name);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(e.arena, from);
        }
        if (e.root.lookup(target) == null) {
            try e.report(from, try std.fmt.allocPrint(e.arena, "unknown key \"{s}\"", .{target}));
            return null;
        }
        // References inside the target are expanded first, by key, so `lookup` again.
        if (!try e.expand(target)) return null;
        const value = e.root.lookup(target).?;
        return switch (value) {
            .string => |s| s,
            .table, .array => {
                try e.report(from, try std.fmt.allocPrint(
                    e.arena,
                    "\"{s}\" is not a scalar",
                    .{target},
                ));
                return null;
            },
            else => try std.fmt.allocPrint(e.arena, "{f}", .{value}),
        };
    }

    fn report(e: *Expander, key: []const u8, message: []const u8) Allocator.Error!void {
        if (e.config.reference_problem != null) return;
        e.config.reference_problem = .{ .key = key, .message = message };
    }
};

fn overlay(config: *Config, result: *Value, layer: Layer) Allocator.Error!void {
    const a = config.cache.allocator();
    const tree_of_layer = config.layers[@backingInt(layer)];
    try config.mergeInto(a, result, try config.foldTree(a, tree_of_layer));
    var leaves: std.ArrayList([]const u8) = .empty;
    try tree_of_layer.leafPaths(a, "", &leaves);
    const sources = config.sources[@backingInt(layer)];
    for (leaves.items) |leaf| {
        const origin: Origin = .{ .layer = layer, .source = sources.get(leaf) orelse "" };
        try config.origins.put(a, try config.foldKey(leaf), origin);
    }
}

fn recordProfile(config: *Config, name: []const u8, selected: Value) Allocator.Error!void {
    const a = config.cache.allocator();
    var leaves: std.ArrayList([]const u8) = .empty;
    try selected.leafPaths(a, "", &leaves);
    const prefix = try path.join(a, config.profiles_key, name);
    for (leaves.items) |leaf| {
        const full = try std.mem.concat(a, u8, &.{ prefix, ".", leaf });
        const file = config.sources[@backingInt(Layer.file)].get(full) orelse "";
        try config.origins.put(a, try config.foldKey(leaf), .{ .layer = .profile, .source = file });
    }
}

fn overlayEnv(config: *Config, result: *Value) Allocator.Error!void {
    const environ = config.environ orelse return;
    const a = config.cache.allocator();
    var candidates: std.ArrayList([]const u8) = .empty;
    try result.leafPaths(a, "", &candidates);
    try config.layers[@backingInt(Layer.flag)].leafPaths(a, "", &candidates);
    try config.layers[@backingInt(Layer.override)].leafPaths(a, "", &candidates);
    try candidates.appendSlice(a, config.known_keys.keys());
    try candidates.appendSlice(a, config.env_bindings.keys());
    var bindings = config.env_bindings;
    if (config.case_insensitive) {
        bindings = .empty;
        var it = config.env_bindings.iterator();
        while (it.next()) |entry| {
            try bindings.put(a, try config.foldKey(entry.key_ptr.*), entry.value_ptr.*);
        }
        for (candidates.items) |*key| key.* = try config.foldKey(key.*);
    }
    for (candidates.items) |key| {
        const name = bindings.get(key) orelse blk: {
            if (!config.automatic_env) continue;
            break :blk try path.toEnvName(a, config.env_prefix, key);
        };
        const text = environ.get(name) orelse continue;
        result.put(a, key, .{ .string = text }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The key crosses a scalar from a lower layer (`a` is set, `a.b` is bound);
            // the lower layer's shape wins and the variable is ignored.
            error.InvalidPath, error.NotATable, error.IndexOutOfRange => continue,
        };
        // Same shape as `result` at this key, so this cannot cross a scalar.
        config.derived_env.put(a, key, .{ .string = text }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPath, error.NotATable, error.IndexOutOfRange => {},
        };
        try config.origins.put(a, key, .{ .layer = .env, .source = name });
    }
}

// -- Reading ---------------------------------------------------------------------------

/// The effective value at `key_path`, or null. Valid until the configuration changes.
pub fn get(config: *Config, key_path: []const u8) Allocator.Error!?Value {
    const tree = try config.resolve();
    return tree.lookup(try config.foldKey(key_path));
}

/// Whether any layer supplies a value at `key_path`.
pub fn isSet(config: *Config, key_path: []const u8) Allocator.Error!bool {
    return try config.get(key_path) != null;
}

/// Which layer, and which file, variable, or flag, supplied the value at `key_path`.
/// For a table, the origin is that of the table's last-set leaf.
pub fn explain(config: *Config, key_path_as_given: []const u8) Allocator.Error!?Origin {
    // Origins are recorded per layer, so they include keys the effective tree does not
    // have: the `profiles` table, and leaves under a table a higher layer replaced.
    const tree = try config.resolve();
    const key_path = try config.foldKey(key_path_as_given);
    if (tree.lookup(key_path) == null) return null;
    if (config.origins.get(key_path)) |origin| return origin;
    // A key spelled differently from how it was recorded (`a."b"` vs `a.b`) or a table.
    const segments = path.split(config.cache.allocator(), key_path) catch return null;
    var best: ?Origin = null;
    var it = config.origins.iterator();
    while (it.next()) |entry| {
        const recorded = path.split(config.cache.allocator(), entry.key_ptr.*) catch continue;
        if (recorded.len < segments.len) continue;
        const prefix_matches = for (segments, recorded[0..segments.len]) |x, y| {
            if (!std.mem.eql(u8, x, y)) break false;
        } else true;
        if (prefix_matches) best = entry.value_ptr.*;
    }
    return best;
}

/// What one layer contributes, before the layers above it: for `profile` and `env`, the
/// values they supplied. Valid until the configuration changes.
pub fn layerTree(config: *Config, layer: Layer) Allocator.Error!Value {
    _ = try config.resolve();
    return switch (layer) {
        .profile => config.derived_profile,
        .env => config.derived_env,
        else => config.layers[@backingInt(layer)],
    };
}

/// Every effective leaf key, sorted. Valid until the configuration changes.
pub fn keys(config: *Config) Allocator.Error![]const []const u8 {
    const value = try config.resolve();
    const a = config.cache.allocator();
    var leaves: std.ArrayList([]const u8) = .empty;
    try value.leafPaths(a, "", &leaves);
    std.mem.sort([]const u8, leaves.items, {}, lessThan);
    return leaves.items;
}

/// `base` and `name` joined with the separator `base` already uses, so a source reads the
/// way it was written: `./snek.toml`, `conf/shared/base.yaml`, `C:\x\snek.toml`. As
/// `platform.files.join`, which `cfg` does not import.
fn joinPath(gpa: Allocator, base: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (base.len == 0) return gpa.dupe(u8, name);
    const windows = @import("builtin").os.tag == .windows;
    const sep: u8 = if (windows and std.mem.indexOfScalar(u8, base, '\\') != null and
        std.mem.indexOfScalar(u8, base, '/') == null) '\\' else '/';
    const trimmed = if (base[base.len - 1] == sep) base[0 .. base.len - 1] else base;
    const out = try std.mem.concat(gpa, u8, &.{ trimmed, &.{sep}, name });
    if (windows) for (out[trimmed.len + 1 ..]) |*c| {
        if (c.* == '/' or c.* == '\\') c.* = sep;
    };
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// What the typed getters can fail with.
pub const GetError = decoding.Error;

/// The part of the configuration below `prefix`, read with keys relative to it, so a
/// component can be handed its own section: `config.view("db").getString("host")` reads
/// `db.host`. A view is two words and allocates nothing until used; it sees every change.
pub fn view(config: *Config, prefix: []const u8) View {
    return .{ .config = config, .prefix = prefix };
}

/// See `view`.
pub const View = struct {
    config: *Config,
    prefix: []const u8,

    /// The full key of `key`, in the configuration's arena.
    pub fn key(v: View, key_path: []const u8) Allocator.Error![]const u8 {
        if (v.prefix.len == 0) return key_path;
        if (key_path.len == 0) return v.prefix;
        return std.mem.concat(v.config.cache.allocator(), u8, &.{ v.prefix, ".", key_path });
    }

    /// A view of a section of this one.
    pub fn view(v: View, prefix: []const u8) Allocator.Error!View {
        return .{ .config = v.config, .prefix = try v.key(prefix) };
    }

    /// `Config.get` of the key below the view's prefix.
    pub fn get(v: View, key_path: []const u8) Allocator.Error!?Value {
        return v.config.get(try v.key(key_path));
    }

    /// `Config.getAs` of the key below the view's prefix.
    pub fn getAs(v: View, comptime T: type, key_path: []const u8, diag: ?*Diagnostic) GetError!?T {
        return v.config.getAs(T, try v.key(key_path), diag);
    }

    /// `Config.getString` of the key below the view's prefix.
    pub fn getString(v: View, key_path: []const u8) GetError!?[]const u8 {
        return v.config.getString(try v.key(key_path));
    }

    /// `Config.getBool` of the key below the view's prefix.
    pub fn getBool(v: View, key_path: []const u8) GetError!?bool {
        return v.config.getBool(try v.key(key_path));
    }

    /// `Config.getInt` of the key below the view's prefix.
    pub fn getInt(v: View, comptime T: type, key_path: []const u8) GetError!?T {
        return v.config.getInt(T, try v.key(key_path));
    }

    /// The section as a `T`, as `Config.decode` decodes the whole; a diagnostic names the
    /// full key, and its file and line when known. A missing section decodes as empty.
    pub fn decode(
        v: View,
        comptime T: type,
        options: decoding.Options,
        diag: ?*Diagnostic,
    ) GetError!T {
        const a = v.config.arena.allocator();
        const section = try v.config.get(v.prefix) orelse Value{ .table = .empty };
        const copy = try section.clone(a);
        return decoding.decode(T, a, copy, options, diag) catch |err| {
            if (diag) |d| {
                d.key = try v.key(d.key);
                v.config.locateDiagnostic(d);
            }
            if (options.errors) |list| for (list.items) |*problem| {
                problem.key = try v.key(problem.key);
                v.config.locateDiagnostic(problem);
            };
            return err;
        };
    }
};

/// The value at `key_path` as a `T`, or null when unset. Coerces like `decode`. Strings in
/// the result are valid until the configuration changes.
pub fn getAs(
    config: *Config,
    comptime T: type,
    key_path: []const u8,
    diag: ?*Diagnostic,
) GetError!?T {
    const value = try config.get(key_path) orelse return null;
    return decoding.decode(T, config.cache.allocator(), value, .{}, diag) catch |err| {
        if (diag) |d| d.key = key_path;
        return err;
    };
}

/// The value at `key_path` as text; numbers and booleans are formatted.
pub fn getString(config: *Config, key_path: []const u8) GetError!?[]const u8 {
    return config.getAs([]const u8, key_path, null);
}

/// The value at `key_path` as a boolean; accepts `true/false/yes/no/on/off/1/0` text.
pub fn getBool(config: *Config, key_path: []const u8) GetError!?bool {
    return config.getAs(bool, key_path, null);
}

/// The value at `key_path` as the integer type `T`, range-checked.
pub fn getInt(config: *Config, comptime T: type, key_path: []const u8) GetError!?T {
    return config.getAs(T, key_path, null);
}

/// The value at `key_path` as a float.
pub fn getFloat(config: *Config, key_path: []const u8) GetError!?f64 {
    return config.getAs(f64, key_path, null);
}

/// The value at `key_path` parsed as a `Duration`, such as `1h30m`.
pub fn getDuration(config: *Config, key_path: []const u8) GetError!?scalar.Duration {
    return config.getAs(scalar.Duration, key_path, null);
}

/// The value at `key_path` parsed as a `ByteSize`, such as `10MiB`.
pub fn getByteSize(config: *Config, key_path: []const u8) GetError!?scalar.ByteSize {
    return config.getAs(scalar.ByteSize, key_path, null);
}

/// The value at `key_path` as a list of strings; text is split on commas.
pub fn getStringList(config: *Config, key_path: []const u8) GetError!?[]const []const u8 {
    return config.getAs([]const []const u8, key_path, null);
}

/// The value at `key_path` as it would be written after a command-line flag: a string as
/// it is, a number or boolean formatted, an array of those joined with commas (for a
/// repeatable flag that splits on `,`). Null when unset, null, a table, or an array holding
/// anything else. The text lives until `deinit`, so it may outlive changes, as flag values
/// must; this is the method `cli.Defaults.from` calls.
pub fn flagText(config: *Config, key_path: []const u8) Allocator.Error!?[]const u8 {
    const value = try config.get(key_path) orelse return null;
    const a = config.arena.allocator();
    switch (value) {
        .array => |array| {
            var out: std.ArrayList(u8) = .empty;
            for (array.items, 0..) |item, i| {
                if (i > 0) try out.append(a, ',');
                try out.appendSlice(a, try scalarText(a, item) orelse return null);
            }
            return out.items;
        },
        else => return scalarText(a, value),
    }
}

/// A scalar's text, in `a`; null for anything else.
fn scalarText(a: Allocator, value: Value) Allocator.Error!?[]const u8 {
    return switch (value) {
        .string => |text| try a.dupe(u8, text),
        .bool => |b| if (b) "true" else "false",
        .int => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .null, .array, .table => null,
    };
}

/// Decodes the whole effective tree as a `T`. Every key `T` declares is also looked up in
/// the environment, even when no other source sets it. The result lives until `deinit`
/// (or, for a configuration made with an arena, as long as the arena: see `init`).
pub fn decode(
    config: *Config,
    comptime T: type,
    options: decoding.Options,
    diag: ?*Diagnostic,
) GetError!T {
    try config.registerKeys(comptime structKeys(T));
    for (comptime decoding.secretKeys(T)) |key| try config.markSecret(key);
    try config.bindEnvs(T);
    const a = config.arena.allocator();
    const copy = try (try config.resolve()).clone(a);
    defer if (options.warnings) |list| config.locateAll(list.items);
    return decoding.decode(T, a, copy, options, diag) catch |err| {
        if (diag) |d| config.locateDiagnostic(d);
        if (options.errors) |list| config.locateAll(list.items);
        return err;
    };
}

fn locateAll(config: *Config, diagnostics: []Diagnostic) void {
    for (diagnostics) |*d| config.locateDiagnostic(d);
}

/// Points a decode diagnostic, which names a key, at the file and line that set the key
/// (or the nearest table above it, for a missing key): fills in `file`, `line`, and
/// `column`. Leaves it as it is when the key came from elsewhere (a default, the
/// environment, a flag), or from text not kept (`loadReader`, a `Source`). `decode` does
/// this itself. `file` lives until the next `reload` or `deinit`; `sourceText` gives the
/// file's text, for `Diagnostic.writeSnippet`.
pub fn locateDiagnostic(config: *Config, d: *Diagnostic) void {
    if (d.key.len == 0 or d.line != 0) return;
    var scratch: std.heap.ArenaAllocator = .init(config.gpa);
    defer scratch.deinit();
    // The key itself, or else the closest table above it that has an origin.
    var prefix = d.key;
    while (true) {
        const origin = config.explain(prefix) catch return;
        if (origin) |o| {
            // A key set by the environment or a flag is not pointed at the file that set
            // the table it is in.
            if (o.layer != .file) return;
            const file = config.fileNamed(o.source) orelse return;
            if (file.text.len == 0) return;
            const at = (locator.locate(scratch.allocator(), file.format, file.text, d.key) catch
                return) orelse return;
            d.file = file.name;
            d.line = at.line;
            d.column = at.column;
            return;
        }
        const dot = std.mem.lastIndexOfScalar(u8, prefix, '.') orelse return;
        prefix = prefix[0..dot];
    }
}

/// The text a file or `loadSource` source named `name` was parsed from, or null when it is
/// not kept (see `locateDiagnostic`).
pub fn sourceText(config: *const Config, name: []const u8) ?[]const u8 {
    const file = config.fileNamed(name) orelse return null;
    return if (file.text.len > 0) file.text else null;
}

fn fileNamed(config: *const Config, name: []const u8) ?*const FileSource {
    var i = config.files.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, config.files.items[i].name, name)) return &config.files.items[i];
    }
    return null;
}

/// The leaf keys a struct type declares, recursively.
fn structKeys(comptime T: type) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        collectKeys(T, "", &out);
        return out;
    }
}

fn collectKeys(
    comptime T: type,
    comptime prefix: []const u8,
    comptime out: *[]const []const u8,
) void {
    const Base = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    const is_table = @typeInfo(Base) == .@"struct" and !decoding.hasParse(Base) and Base != Value;
    if (!is_table) {
        out.* = out.* ++ .{prefix};
        return;
    }
    const info = @typeInfo(Base).@"struct";
    for (info.field_names) |name| {
        const key = decoding.metaOption(Base, name, "key", @as([]const u8, name));
        const field_type = info.field_types[std.meta.fieldIndex(Base, name).?];
        collectKeys(field_type, if (prefix.len == 0) key else prefix ++ "." ++ key, out);
    }
}

/// What `write` and `snapshot` write.
pub const WriteOptions = struct {
    /// Write one layer instead of the effective tree.
    layer: ?Layer = null,
    /// Replace secret values with `redacted`.
    redact: bool = true,
};

/// Writes the effective tree, or one layer, in `format`.
pub fn write(
    config: *Config,
    writer: *Io.Writer,
    format: Format,
    options: WriteOptions,
) (Io.Writer.Error || error{Unrepresentable} || Allocator.Error)!void {
    try format.write(writer, try config.snapshot(options));
}

/// The tree `write` writes: the effective tree or one layer, secrets redacted unless told
/// otherwise. Valid until the configuration changes.
pub fn snapshot(config: *Config, options: WriteOptions) Allocator.Error!Value {
    var value = try config.resolve();
    if (options.layer) |layer| value = switch (layer) {
        .profile => config.derived_profile,
        .env => config.derived_env,
        else => config.layers[@backingInt(layer)],
    };
    if (options.redact and config.secrets.count() > 0) {
        const a = config.cache.allocator();
        value = try value.clone(a);
        for (config.secrets.keys()) |secret| {
            // The effective tree folds key case; a layer is written as it was given.
            const key = if (options.layer == null) try config.foldKey(secret) else secret;
            if (value.lookup(key) == null) continue;
            value.put(a, key, .{ .string = redacted }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // `lookup` just found the key, so every segment on the way is a container.
                error.InvalidPath, error.NotATable, error.IndexOutOfRange => unreachable,
            };
        }
    }
    return value;
}

const testing = std.testing;

const App = struct {
    server: struct {
        host: []const u8 = "localhost",
        port: u16 = 8080,
    } = .{},
    debug: bool = false,
    token: ?[]const u8 = null,

    pub const meta = .{ .token = .{ .secret = true } };
};

test "precedence across layers" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefaults(App{});
    try config.loadSource("a.json", "{\"server\": {\"port\": 1, \"host\": \"file\"}}", .json, null);
    try config.loadSource("b.json", "{\"server\": {\"port\": 2}}", .json, null);
    try testing.expectEqual(2, (try config.get("server.port")).?.int);
    try testing.expectEqualStrings("file", (try config.get("server.host")).?.string);

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_SERVER_PORT", "3");
    config.useEnv(&environ);
    try config.automaticEnv("app");
    try testing.expectEqual(3, (try config.getInt(u16, "server.port")).?);

    try config.setFlag("server.port", "4");
    try testing.expectEqual(4, (try config.getInt(u16, "server.port")).?);

    try config.set("server.port", 5);
    try testing.expectEqual(5, (try config.getInt(u16, "server.port")).?);
    try testing.expect(config.unset("server.port"));
    try testing.expectEqual(4, (try config.getInt(u16, "server.port")).?);
}

test "explain reports the origin" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefault("a", 1);
    try config.loadSource("conf.toml", "{\"b\": 2, \"t\": {\"x\": 1}}", .json, null);
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("SECRET_C", "3");
    config.useEnv(&environ);
    try config.bindEnv("c", "SECRET_C");
    const records = [_]struct { name: []const u8, value: []const u8 }{.{
        .name = "dry-run",
        .value = "true",
    }};
    try config.bindFlags(&records, .{});

    try testing.expectEqual(Origin{ .layer = .default }, (try config.explain("a")).?);
    const b = (try config.explain("b")).?;
    try testing.expectEqual(Layer.file, b.layer);
    try testing.expectEqualStrings("conf.toml", b.source);
    try testing.expectEqualStrings("SECRET_C", (try config.explain("c")).?.source);
    try testing.expectEqualStrings("--dry-run", (try config.explain("dry_run")).?.source);
    try testing.expectEqual(true, (try config.get("dry_run")).?.bool);
    try testing.expectEqual(Layer.file, (try config.explain("t")).?.layer);
    try testing.expectEqual(null, try config.explain("missing"));
}

test "profiles overlay the files" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.loadSource("c.json",
        \\{"port": 1, "profiles": {"staging": {"port": 2}, "prod": {"port": 3}}}
    , .json, null);
    try testing.expectEqual(2, config.profileNames().len);
    try testing.expectEqual(1, (try config.get("port")).?.int);
    try testing.expectEqual(null, try config.get("profiles"));
    try config.useProfile("prod");
    try testing.expectEqual(3, (try config.get("port")).?.int);
    const origin = (try config.explain("port")).?;
    try testing.expectEqual(Layer.profile, origin.layer);
    try testing.expectEqualStrings("c.json", origin.source);
}

test "decode reads the environment for declared keys" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("SVC_SERVER_HOST", "example.com");
    try environ.put("SVC_TOKEN", "hunter2");
    config.useEnv(&environ);
    try config.automaticEnv("svc");
    const app = try config.decode(App, .{}, null);
    try testing.expectEqualStrings("example.com", app.server.host);
    try testing.expectEqual(8080, app.server.port);
    try testing.expectEqualStrings("hunter2", app.token.?);
    try config.set("debug", true);
    // `app` was copied into the long-lived arena, so it survives the rebuild.
    _ = try config.resolve();
    try testing.expectEqualStrings("example.com", app.server.host);
}

test "write redacts secrets" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefaults(App{ .token = "hunter2" });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try config.write(&out.writer, .json, .{});
    try testing.expect(std.mem.indexOf(u8, out.written(), "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), redacted) != null);
    out.clearRetainingCapacity();
    try config.write(&out.writer, .json, .{ .redact = false });
    try testing.expect(std.mem.indexOf(u8, out.written(), "hunter2") != null);
}

test "keys are sorted leaves" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefaults(App{});
    const all = try config.keys();
    const expected = [_][]const u8{ "debug", "server.host", "server.port" };
    try testing.expectEqual(expected.len, all.len);
    for (expected, all) |e, k| try testing.expectEqualStrings(e, k);
}

test "repeated flags become arrays" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    const records = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "tag", .value = "a" },
        .{ .name = "tag", .value = "b" },
        .{ .name = "tag", .value = "c" },
    };
    try config.bindFlags(&records, .{ .prefix = "build" });
    const tags = (try config.getStringList("build.tag")).?;
    try testing.expectEqual(3, tags.len);
    try testing.expectEqualStrings("c", tags[2]);
}

test flagText {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.loadSource("app.toml",
        \\name = "web"
        \\port = 8080
        \\ratio = 0.5
        \\debug = true
        \\tags = ["a", "b", 3]
        \\mixed = [1, [2]]
        \\[serve]
        \\host = "::1"
    , .toml, null);
    try testing.expectEqualStrings("web", (try config.flagText("name")).?);
    try testing.expectEqualStrings("8080", (try config.flagText("port")).?);
    try testing.expectEqualStrings("0.5", (try config.flagText("ratio")).?);
    try testing.expectEqualStrings("true", (try config.flagText("debug")).?);
    try testing.expectEqualStrings("a,b,3", (try config.flagText("tags")).?);
    try testing.expectEqualStrings("::1", (try config.flagText("serve.host")).?);
    try testing.expectEqual(null, try config.flagText("mixed"));
    try testing.expectEqual(null, try config.flagText("serve"));
    try testing.expectEqual(null, try config.flagText("missing"));
    // The text outlives changes to the configuration.
    const name = (try config.flagText("name")).?;
    try config.set("name", "changed");
    try testing.expectEqualStrings("web", name);
    try testing.expectEqualStrings("changed", (try config.flagText("name")).?);
}

test "typed getters report mismatches" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.set("name", "x");
    try config.set("timeout", "1m");
    try testing.expectEqual(std.time.ns_per_min, (try config.getDuration("timeout")).?.ns);
    try testing.expectEqual(null, try config.getBool("missing"));
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, config.getAs(u8, "name", &diag));
    try testing.expectEqualStrings("name", diag.key);
}

test "a non-table document is rejected" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, config.loadSource("x.json", "[1]", .json, &diag));
    try testing.expectEqualStrings(
        "a configuration file must hold a table at the top level",
        diag.message,
    );
}

test "the configuration directory follows each system's convention" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expectEqual(null, try appConfigDir(a, &environ, .linux, "app"));
    try environ.put("HOME", "/home/u");
    try environ.put("USERPROFILE", "C:\\Users\\u");
    const linux = (try appConfigDir(a, &environ, .linux, "app")).?;
    try testing.expectEqualStrings("/home/u/.config/app", linux);
    const mac = (try appConfigDir(a, &environ, .macos, "app")).?;
    try testing.expectEqualStrings("/home/u/Library/Application Support/app", mac);
    const win = (try appConfigDir(a, &environ, .windows, "app")).?;
    try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Roaming\\app", win);
    try environ.put("XDG_CONFIG_HOME", "relative"); // Ignored, as XDG says.
    try environ.put("APPDATA", "D:\\Roaming");
    try testing.expectEqualStrings(linux, (try appConfigDir(a, &environ, .linux, "app")).?);
    const roaming = (try appConfigDir(a, &environ, .windows, "app")).?;
    try testing.expectEqualStrings("D:\\Roaming\\app", roaming);
    try environ.put("XDG_CONFIG_HOME", "/x");
    try testing.expectEqualStrings("/x/app", (try appConfigDir(a, &environ, .freebsd, "app")).?);
}

test "loadAppFile: the named file, the variable's, or the one in the configuration directory" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "conf/app");
    try tmp.dir.writeFile(io, .{ .sub_path = "conf/app/config.toml", .data = "a = 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.toml", .data = "a = 2\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const conf = try std.fs.path.join(testing.allocator, &.{ root, "conf" });
    defer testing.allocator.free(conf);
    const other = try std.fs.path.join(testing.allocator, &.{ root, "other.toml" });
    defer testing.allocator.free(other);
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", conf);
    try environ.put("HOME", root);

    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try testing.expectError(error.NoConfigDir, config.loadAppFile(io, "app", .{}, null));
    config.useEnv(&environ);
    if (@import("builtin").os.tag != .windows) {
        const found = try config.loadAppFile(io, "app", .{ .env = "APP_CONFIG" }, null);
        try testing.expect(found.found);
        try testing.expect(std.mem.endsWith(u8, found.path, "/conf/app/config.toml"));
        try testing.expectEqual(1, (try config.getInt(u8, "a")).?);
    }
    try environ.put("APP_CONFIG", other);
    const from_env = try config.loadAppFile(io, "app", .{ .env = "APP_CONFIG" }, null);
    try testing.expectEqualStrings(other, from_env.path);
    try testing.expectEqual(2, (try config.getInt(u8, "a")).?);
    // A missing file is not an error: it says where one would go.
    const missing = try config.loadAppFile(io, "app", .{ .path = "/nonexistent/app.toml" }, null);
    try testing.expect(!missing.found);
    try testing.expectEqualStrings("/nonexistent/app.toml", missing.path);
}

test "findFile searches directories and extensions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "etc");
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/app.yaml", .data = "a: 1\n" });
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base_buffer);
    const base = base_buffer[0..base_len];

    var config: Config = .init(testing.allocator);
    defer config.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("BASE", base);
    config.useEnv(&environ);
    const dirs = [_][]const u8{ "$UNSET/x", "$BASE", "$BASE/etc" };
    const found = (try config.findFile(io, .{ .name = "app", .dirs = &dirs })).?;
    try testing.expect(std.mem.endsWith(u8, found, "app.yaml"));
    try config.loadFile(io, .cwd(), found, null, null);
    try testing.expectEqual(1, (try config.get("a")).?.int);
    try testing.expectEqual(null, try config.findFile(io, .{ .name = "nope", .dirs = &dirs }));
}

test "findFile expands ~ from HOME and skips unset or empty variables" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, ".config/app");
    try tmp.dir.writeFile(io, .{ .sub_path = ".config/app/app.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".config/app/app.toml", .data = "" });
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buffer[0..try tmp.dir.realPath(io, &base_buffer)];

    var config: Config = .init(testing.allocator);
    defer config.deinit();
    const dirs = [_][]const u8{ "$UNSET", "$EMPTY/.config/app", "~/.config/app" };
    // Without an environment, every variable is unset and `~` cannot expand.
    try testing.expectEqual(null, try config.findFile(io, .{ .name = "app", .dirs = &dirs }));

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("EMPTY", "");
    config.useEnv(&environ);
    try testing.expectEqual(null, try config.findFile(io, .{ .name = "app", .dirs = &dirs }));

    try environ.put("HOME", base);
    const found = (try config.findFile(io, .{ .name = "app", .dirs = &dirs })).?;
    try testing.expect(std.mem.startsWith(u8, found, base));
    // Formats are tried in order, TOML first by default.
    try testing.expect(std.mem.endsWith(u8, found, "app.toml"));
    const json_only = (try config.findFile(io, .{
        .name = "app",
        .dirs = &.{"~/.config/app"},
        .formats = &.{.json},
    })).?;
    try testing.expect(std.mem.endsWith(u8, json_only, "app.json"));
    // `~` alone is the home directory; `~name` is not expanded.
    try testing.expectEqual(null, try config.findFile(io, .{ .name = "app", .dirs = &.{"~"} }));
    try testing.expectEqual(null, try config.findFile(io, .{ .name = "app", .dirs = &.{"~x"} }));
}

test "loadFile reports missing files, unknown formats, and syntax errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.toml", .data = "a = 1\nb = \n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "good.txt", .data = "a: 1\n" });

    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try testing.expectError(
        error.FileNotFound,
        config.loadFile(io, tmp.dir, "missing.toml", null, null),
    );
    // The format is decided before the file is read.
    try testing.expectError(
        error.UnknownFormat,
        config.loadFile(io, tmp.dir, "missing.xml", null, null),
    );
    try testing.expectError(
        error.UnknownFormat,
        config.loadFile(io, tmp.dir, "good.txt", null, null),
    );
    var diag: Diagnostic = .{};
    try testing.expectError(
        error.SyntaxError,
        config.loadFile(io, tmp.dir, "bad.toml", null, &diag),
    );
    try testing.expectEqual(2, diag.line);
    try testing.expectEqual(5, diag.column);
    try testing.expectEqualStrings("expected a value", diag.message);
    try testing.expectEqualStrings("bad.toml", diag.file);
    var shown: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&shown, "{f}", .{diag});
    try testing.expectEqualStrings("bad.toml:2:5: expected a value", line);
    // A failed load adds nothing.
    try testing.expectEqual(0, (try config.keys()).len);
    // An explicit format overrides the extension.
    try config.loadFile(io, tmp.dir, "good.txt", .yaml, null);
    const origin = (try config.explain("a")).?;
    try testing.expectEqualStrings("good.txt", origin.source);
}

test "write one layer" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefault("a", 1);
    try config.loadSource("f.json", "{\"b\": 2, \"profiles\": {\"p\": {\"b\": 3}}}", .json, null);
    try config.set("c", 3);
    try config.setDefault("token", "hunter2");
    try config.markSecret("token");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try config.write(&out.writer, .json, .{ .layer = .default });
    try testing.expectEqualStrings(
        "{\n  \"a\": 1,\n  \"token\": \"<redacted>\"\n}\n",
        out.written(),
    );
    out.clearRetainingCapacity();
    // The file layer as loaded, profiles included.
    try config.write(&out.writer, .yaml, .{ .layer = .file });
    try testing.expectEqualStrings("b: 2\nprofiles:\n  p:\n    b: 3\n", out.written());
    out.clearRetainingCapacity();
    try config.write(&out.writer, .toml, .{ .layer = .override });
    try testing.expectEqualStrings("c = 3\n", out.written());
    out.clearRetainingCapacity();
    try config.write(&out.writer, .toml, .{ .layer = .env });
    try testing.expectEqualStrings("", out.written());
    // Redacting works on a copy: the layer keeps its value.
    try testing.expectEqualStrings("hunter2", (try config.getString("token")).?);
}

test "a dotenv source expands variables from the environment given to useEnv" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    const source = "URL=http://${HOST:-localhost}:$PORT/\n";
    try config.loadSource("a.env", source, .dotenv, null);
    try testing.expectEqualStrings("http://localhost:/", (try config.getString("url")).?);

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("HOST", "example.com");
    try environ.put("PORT", "80");
    config.useEnv(&environ);
    try config.loadSource("b.env", source, .dotenv, null);
    try testing.expectEqualStrings("http://example.com:80/", (try config.getString("url")).?);
    try testing.expectEqualStrings("b.env", (try config.explain("url")).?.source);
}

test "bindEnv wins over the automatic name" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefault("server.port", 1);
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_SERVER_PORT", "2");
    try environ.put("PORT", "3");
    config.useEnv(&environ);
    try config.automaticEnv("app");
    try testing.expectEqual(2, (try config.getInt(u16, "server.port")).?);
    try config.bindEnv("server.port", "PORT");
    try testing.expectEqual(3, (try config.getInt(u16, "server.port")).?);
    try testing.expectEqualStrings("PORT", (try config.explain("server.port")).?.source);
    // A bound key reads only its own variable: when that is unset, the automatic name is
    // not consulted and the lower layers show through.
    try config.bindEnv("server.port", "UNSET_PORT");
    try testing.expectEqual(1, (try config.getInt(u16, "server.port")).?);
    try testing.expectEqual(Layer.default, (try config.explain("server.port")).?.layer);
    // A binding needs no other source for its key.
    try environ.put("ONLY_ENV", "x");
    try config.bindEnv("extra.key", "ONLY_ENV");
    try testing.expectEqualStrings("x", (try config.getString("extra.key")).?);
}

test "an environment variable that crosses a lower layer's scalar is ignored" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefault("a", 1);
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("AB", "x");
    try environ.put("A_B", "y");
    config.useEnv(&environ);
    try config.bindEnv("a.b", "AB");
    try config.automaticEnv("");
    try config.registerKeys(&.{"a.b"});
    try testing.expectEqual(1, (try config.get("a")).?.int);
    try testing.expectEqual(null, try config.get("a.b"));
    try testing.expectEqual(null, try config.explain("a.b"));
    try testing.expectEqual(Layer.default, (try config.explain("a")).?.layer);
}

test "useProfile(null) clears the profile, and profileNames lists them" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try testing.expectEqual(0, config.profileNames().len);
    try config.loadSource("c.yaml",
        \\port: 1
        \\profiles:
        \\  staging: {port: 2}
        \\  prod:
        \\    port: 3
        \\    only: here
    , .yaml, null);
    const names = config.profileNames();
    try testing.expectEqual(2, names.len);
    try testing.expectEqualStrings("staging", names[0]);
    try testing.expectEqualStrings("prod", names[1]);
    try config.useProfile("prod");
    try testing.expectEqual(3, (try config.get("port")).?.int);
    try testing.expectEqualStrings("here", (try config.getString("only")).?);
    try config.useProfile(null);
    try testing.expectEqual(1, (try config.get("port")).?.int);
    try testing.expectEqual(null, try config.get("only"));
    try testing.expectEqual(Layer.file, (try config.explain("port")).?.layer);
    // A profile that does not exist changes nothing.
    try config.useProfile("nope");
    try testing.expectEqual(1, (try config.get("port")).?.int);
    // Profile keys are not part of the effective tree, so they have no origin either.
    try testing.expectEqual(null, try config.explain("profiles.prod.port"));
    try testing.expectEqual(null, try config.explain("profiles"));
}

test "profileNames is empty when profiles is not a table" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.loadSource("c.json", "{\"profiles\": [1]}", .json, null);
    try testing.expectEqual(0, config.profileNames().len);
    try config.useProfile("x");
    try testing.expectEqual(0, (try config.keys()).len);
}

test "explain on a table key, a quoted spelling, and a replaced table" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefault("server.host", "h");
    try config.setDefault("server.port", 1);
    try config.loadSource("f.toml", "[server]\nport = 2\n", .toml, null);
    // A table reports its last-recorded leaf.
    const table = (try config.explain("server")).?;
    try testing.expectEqual(Layer.file, table.layer);
    try testing.expectEqualStrings("f.toml", table.source);
    try testing.expectEqual(Layer.default, (try config.explain("\"server\".\"host\"")).?.layer);
    try testing.expectEqual(null, try config.explain("server.missing"));
    try testing.expectEqual(null, try config.explain("bad..path"));
    // An override replaces the table with a scalar: the old leaves have no origin.
    try config.set("server", "flat");
    try testing.expectEqual(Layer.override, (try config.explain("server")).?.layer);
    try testing.expectEqual(null, try config.explain("server.port"));
}

test "Origin.format" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}; {f}", .{
        Origin{ .layer = .env, .source = "APP_PORT" },
        Origin{ .layer = .default },
    });
    try testing.expectEqualStrings("env (APP_PORT); default", writer.buffered());
}

test "setDefaults then strict decode" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefaults(App{ .token = "t" });
    const app = try config.decode(App, .{ .strict = true }, null);
    try testing.expectEqual(8080, app.server.port);
    try testing.expectEqualStrings("t", app.token.?);
    try testing.expect(config.isSecret("token"));
    try config.loadSource("x.json", "{\"server\": {\"prot\": 1}}", .json, null);
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnknownField, config.decode(App, .{ .strict = true }, &diag));
    try testing.expectEqualStrings("server.prot", diag.key);
    _ = try config.decode(App, .{}, null);
}

test "meta .env binds a variable to a field" {
    const Settings = struct {
        server: struct {
            port: u16 = 8080,
            pub const meta = .{ .port = .{ .env = "PORT" } };
        } = .{},
        token: ?[]const u8 = null,
        pub const meta = .{ .token = .{ .env = "API_TOKEN", .secret = true } };
    };
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("PORT", "9000");
    try environ.put("API_TOKEN", "t");
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    config.useEnv(&environ);
    try config.setDefaults(Settings{});
    try testing.expectEqual(9000, (try config.getInt(u16, "server.port")).?);
    try testing.expectEqual(Layer.env, (try config.explain("server.port")).?.layer);
    // `decode` binds them too, and an explicit `bindEnv` wins.
    var other: Config = .init(testing.allocator);
    defer other.deinit();
    other.useEnv(&environ);
    try other.bindEnv("server.port", "OTHER_PORT");
    const settings = try other.decode(Settings, .{}, null);
    try testing.expectEqualStrings("t", settings.token.?);
    try testing.expectEqual(8080, settings.server.port);
}

test "compile-time defaults from a .zon file" {
    const Settings = struct {
        server: struct { host: []const u8 = "localhost", port: u16 = 8080 } = .{},
        level: enum { info, debug } = .info,
        tags: []const []const u8 = &.{},
        ratio: f64 = 1,
        debug: bool = false,
        token: ?[]const u8 = null,

        pub const meta = .{ .token = .{ .secret = true } };
    };
    const defaults: Settings = @import("testdata/defaults.zon");
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefaults(defaults);
    try testing.expectEqualStrings("0.0.0.0", (try config.getString("server.host")).?);
    try testing.expectEqual(9000, (try config.getInt(u16, "server.port")).?);
    try testing.expectEqualStrings("debug", (try config.getString("level")).?);
    try testing.expect(config.isSecret("token"));
    const settings = try config.decode(Settings, .{ .strict = true }, null);
    try testing.expectEqualStrings("api", settings.tags[1]);
    try testing.expectEqual(0.75, settings.ratio);
    try testing.expectEqual(false, settings.debug);

    // The ZON codec reads the same file to the same tree, apart from the field left to
    // its default.
    const a = config.arena.allocator();
    var tree = try @import("zon.zig").parse(a, @embedFile("testdata/defaults.zon"), null);
    try tree.put(a, "debug", .{ .bool = false });
    try testing.expect(tree.eql(config.layers[@backingInt(Layer.default)]));
}

test "a .zon file loads like any other" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.loadSource("c.zon", ".{ .server = .{ .port = 1 }, .debug = true }", .zon, null);
    const app = try config.decode(App, .{ .strict = true }, null);
    try testing.expectEqual(1, app.server.port);
    try testing.expectEqual(true, app.debug);
    var diag: Diagnostic = .{};
    try testing.expectError(
        error.SyntaxError,
        config.loadSource("bad.zon", ".{\n    .a = 1,\n    .a = 2,\n}", .zon, &diag),
    );
    try testing.expectEqual(2, diag.line);
    try testing.expectEqualStrings("duplicate struct field name", diag.message);
    try testing.expectError(error.SyntaxError, config.loadSource("s.zon", "1", .zon, &diag));
    try testing.expectEqualStrings(
        "a configuration file must hold a table at the top level",
        diag.message,
    );
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try config.write(&out.writer, .zon, .{});
    try testing.expectEqualStrings(
        \\.{
        \\    .server = .{
        \\        .port = 1,
        \\    },
        \\    .debug = true,
        \\}
        \\
    , out.written());
}

test "decode reports a bad environment value by key" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_SERVER_PORT", "eighty");
    config.useEnv(&environ);
    try config.automaticEnv("APP");
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, config.decode(App, .{}, &diag));
    try testing.expectEqualStrings("server.port", diag.key);
}

test "repeated mutation rebuilds without leaking or growing the cache" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefaults(App{});
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_DEBUG", "true");
    config.useEnv(&environ);
    try config.automaticEnv("app");
    var settled: usize = 0;
    for (0..2000) |i| {
        try config.set("server.port", @as(u16, @intCast(i)));
        try testing.expectEqual(i, (try config.getInt(u16, "server.port")).?);
        try testing.expectEqual(true, (try config.getBool("debug")).?);
        _ = try config.keys();
        _ = try config.explain("server");
        if (i == 100) settled = config.cache.queryCapacity();
    }
    // The effective tree is rebuilt in a reset arena, so its memory stays bounded.
    try testing.expect(config.cache.queryCapacity() <= 2 * settled);
}

test "typed getters coerce and report" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.loadSource("c.yaml",
        \\port: 8080
        \\ratio: 0.5
        \\on: "yes"
        \\size: 10KiB
        \\tags: [a, b]
        \\csv: "x,y"
        \\nested: {deep: {n: "not a number"}}
    , .yaml, null);
    try testing.expectEqualStrings("8080", (try config.getString("port")).?);
    try testing.expectEqual(0.5, (try config.getFloat("ratio")).?);
    try testing.expectEqual(8080.0, (try config.getFloat("port")).?);
    try testing.expectEqual(true, (try config.getBool("on")).?);
    try testing.expectEqual(10 * 1024, (try config.getByteSize("size")).?.bytes);
    try testing.expectEqual(2, (try config.getStringList("tags")).?.len);
    try testing.expectEqualStrings("y", (try config.getStringList("csv")).?[1]);
    try testing.expectError(error.InvalidValue, config.getInt(u8, "port"));
    try testing.expectError(error.InvalidValue, config.getString("nested"));
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, config.getAs(u8, "nested.deep.n", &diag));
    try testing.expectEqualStrings("nested.deep.n", diag.key);
    try testing.expect(try config.isSet("nested.deep"));
    try testing.expect(!try config.isSet("nested.shallow"));
    try testing.expect(!config.unset("port")); // Only the override layer is unset.
    try testing.expectEqual(null, try config.getDuration("missing"));
}

test "bindFlags with a prefix, without snake case, and with typed text" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    const Record = struct { name: []const u8, value: []const u8 };
    const records = [_]Record{
        .{ .name = "dry-run", .value = "true" },
        .{ .name = "level", .value = "3" },
        .{ .name = "ratio", .value = "0.25" },
        .{ .name = "name", .value = "x y" },
        .{ .name = "level", .value = "four" },
    };
    try config.bindFlags(&records, .{ .prefix = "cmd", .snake_case = false });
    try testing.expectEqual(true, (try config.get("cmd.dry-run")).?.bool);
    try testing.expectEqual(0.25, (try config.get("cmd.ratio")).?.float);
    const level = (try config.get("cmd.level")).?.array.items;
    try testing.expectEqual(3, level[0].int);
    try testing.expectEqualStrings("four", level[1].string);
    try testing.expectEqualStrings("--level", (try config.explain("cmd.level")).?.source);
    try config.setFlag("cmd.name", "z");
    try testing.expectEqualStrings("z", (try config.getString("cmd.name")).?);
    // Within one call, a flag cannot nest under another flag's value.
    const clash = [_]Record{
        .{ .name = "a", .value = "1" },
        .{ .name = "a.b", .value = "2" },
    };
    try testing.expectError(error.NotATable, config.bindFlags(&clash, .{}));
    // Across calls the layer merges as layers do: a later table replaces a scalar.
    try config.setFlag("cmd.name.x", "1");
    try testing.expectEqual(1, (try config.get("cmd.name.x")).?.int);
}

test "bindFlags sets the key a record names, and leaves out flags that are not settings" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefaults(struct {
        depth: u8 = 3,
        fetch: struct { concurrency: u8 = 4 } = .{},
    }{});
    const Record = struct { name: []const u8, value: []const u8, key: ?[]const u8 = null };
    const records = [_]Record{
        .{ .name = "config", .value = "/etc/app.toml" },
        .{ .name = "depth", .value = "1" },
        .{ .name = "jobs", .value = "8", .key = "fetch.concurrency" },
    };
    try config.bindFlags(&records, .{});
    try testing.expectEqual(null, try config.get("config"));
    try testing.expectEqual(1, (try config.getInt(u8, "depth")).?);
    try testing.expectEqual(8, (try config.getInt(u8, "fetch.concurrency")).?);
    try testing.expectEqualStrings("--jobs", (try config.explain("fetch.concurrency")).?.source);
    // `setFlag` names its key, so it always binds.
    try config.setFlag("extra", "x");
    try testing.expectEqualStrings("x", (try config.getString("extra")).?);
}

test "secrets nested and in arrays are redacted" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.loadSource("c.json",
        \\{"db": {"url": "postgres://u:p@h"}, "keys": ["k1", "k2"]}
    , .json, null);
    try config.markSecret("db.url");
    try config.markSecret("keys.1");
    try config.markSecret("not.there");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try config.write(&out.writer, .json, .{ .redact = true });
    try testing.expect(std.mem.indexOf(u8, out.written(), "postgres") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "k2") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "k1") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "not") == null);
    try testing.expect(config.isSecret("db.url"));
    try testing.expect(!config.isSecret("db"));
}

test "a scalar or empty document is handled per format" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try testing.expectError(
        error.SyntaxError,
        config.loadSource("x.yaml", "just text", .yaml, null),
    );
    try config.loadSource("e.yaml", "", .yaml, null);
    try config.loadSource("e.toml", "", .toml, null);
    try config.loadSource("e.env", "", .dotenv, null);
    try testing.expectEqual(0, (try config.keys()).len);
}

test "write shows the derived profile and env layers" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.loadSource("c.json",
        \\{"port": 1, "name": "n", "profiles": {"prod": {"port": 2}}}
    , .json, null);
    try config.useProfile("prod");
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_NAME", "from-env");
    config.useEnv(&environ);
    try config.automaticEnv("APP");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try config.write(&out.writer, .json, .{ .layer = .profile });
    try testing.expectEqualStrings("{\n  \"port\": 2\n}\n", out.written());
    out.clearRetainingCapacity();
    try config.write(&out.writer, .json, .{ .layer = .env });
    try testing.expectEqualStrings("{\n  \"name\": \"from-env\"\n}\n", out.written());
}

test "lists at an append key accumulate across files and layers" {
    const Settings = struct {
        plugins: []const []const u8 = &.{"core"},
        tags: []const []const u8 = &.{"default"},
        pub const meta = .{ .plugins = .{ .merge = .append } };
    };
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.setDefaults(Settings{});
    try config.loadSource("a.json", "{\"plugins\": [\"a\"], \"tags\": [\"a\"]}", .json, null);
    try config.loadSource("b.json", "{\"plugins\": [\"b\"], \"tags\": [\"b\"]}", .json, null);
    const plugins = (try config.get("plugins")).?.array.items;
    try testing.expectEqual(3, plugins.len);
    try testing.expectEqualStrings("core", plugins[0].string);
    try testing.expectEqualStrings("a", plugins[1].string);
    try testing.expectEqualStrings("b", plugins[2].string);
    // Without the strategy, the last list wins.
    const tags = (try config.get("tags")).?.array.items;
    try testing.expectEqual(1, tags.len);
    try testing.expectEqualStrings("b", tags[0].string);

    try config.setMerge("plugins", .replace);
    try config.set("plugins", &[_][]const u8{"only"});
    try testing.expectEqual(1, (try config.get("plugins")).?.array.items.len);
}

test "loadDir merges conf.d files in name order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "conf.d/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "conf.d/20-local.toml", .data = "port = 2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "conf.d/10-base.yaml", .data = "port: 1\nname: x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "conf.d/.hidden.toml", .data = "port = 9\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "conf.d/README.md", .data = "# not config\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "conf.d/sub/30.toml", .data = "port = 3\n" });

    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try testing.expectEqual(2, try config.loadDir(io, tmp.dir, "conf.d", null));
    try testing.expectEqual(2, (try config.get("port")).?.int);
    try testing.expectEqualStrings("x", (try config.get("name")).?.string);
    const origin = (try config.explain("port")).?;
    try testing.expect(std.mem.endsWith(u8, origin.source, "20-local.toml"));
    try testing.expectError(error.FileNotFound, config.loadDir(io, tmp.dir, "missing", null));
}

test "reload re-reads files and reports what changed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "app.toml", .data = "port = 1\nname = \"a\"\n" });

    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.loadFile(io, tmp.dir, "app.toml", null, null);
    try config.loadSource("inline", "{\"extra\": true}", .json, null);
    try config.set("forced", 1);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(0, (try config.reload(io, a, null)).len);

    try tmp.dir.writeFile(io, .{ .sub_path = "app.toml", .data = "port = 2\nadded = 3\n" });
    const changes = try config.reload(io, a, null);
    try testing.expectEqual(3, changes.len);
    try testing.expectEqualStrings("added", changes[0].key);
    try testing.expectEqualStrings("name", changes[1].key);
    try testing.expectEqual(null, changes[1].new);
    try testing.expectEqualStrings("port", changes[2].key);
    try testing.expectEqual(2, changes[2].new.?.int);
    // The other sources are untouched.
    try testing.expect((try config.get("extra")).?.bool);
    try testing.expectEqual(1, (try config.get("forced")).?.int);

    // A broken file changes nothing.
    try tmp.dir.writeFile(io, .{ .sub_path = "app.toml", .data = "port = \n" });
    try testing.expectError(error.SyntaxError, config.reload(io, a, null));
    try testing.expectEqual(2, (try config.get("port")).?.int);
}

test "ignoreKeyCase makes keys from every source one key" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_SERVER_HOST", "from-env");
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    config.ignoreKeyCase();
    config.useEnv(&environ);
    try config.automaticEnv("APP");
    try config.setDefault("Server.Port", 1);
    try config.loadSource("a.yaml", "server:\n  PORT: 2\n  Host: file\nToken: s\n", .yaml, null);
    try config.markSecret("TOKEN");
    try testing.expectEqual(2, (try config.get("SERVER.port")).?.int);
    try testing.expectEqualStrings("from-env", (try config.get("server.host")).?.string);
    try testing.expectEqual(Layer.file, (try config.explain("Server.Port")).?.layer);
    try testing.expect(config.isSecret("token"));
    const keys_found = try config.keys();
    try testing.expectEqual(3, keys_found.len);
    try testing.expectEqualStrings("server.host", keys_found[0]);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try config.write(&out.writer, .json, .{});
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"token\": \"<redacted>\"") != null);
}

test "references expand across layers, and cycles and missing keys are reported" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    config.useReferences();
    try config.loadSource("a.toml",
        \\host = "example.com"
        \\port = 8080
        \\url = "http://${host}:${port}/${path}"
        \\path = "v1"
        \\literal = "$${host}"
        \\[nested]
        \\again = "${url}"
    , .toml, null);
    try config.set("path", "v2");
    try testing.expectEqualStrings("http://example.com:8080/v2", (try config.get("url")).?.string);
    const again = (try config.get("nested.again")).?.string;
    try testing.expectEqualStrings("http://example.com:8080/v2", again);
    try testing.expectEqualStrings("${host}", (try config.get("literal")).?.string);
    try config.checkReferences(null);

    try config.set("a", "${b}");
    try config.set("b", "x${a}");
    try config.set("c", "${missing}");
    var diag: Diagnostic = .{};
    try testing.expectError(error.BadReference, config.checkReferences(&diag));
    // Reported at the key whose reference closes the cycle.
    try testing.expectEqualStrings("b", diag.key);
    try testing.expectEqualStrings("reference cycle: a -> b -> a", diag.message);
    try testing.expectEqualStrings("${b}", (try config.get("a")).?.string);
    try testing.expectEqualStrings("${missing}", (try config.get("c")).?.string);
}

test "secret references resolve at load and are redacted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "db-password", .data = "hunter2\n" });
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buffer[0..try tmp.dir.realPath(io, &base_buffer)];
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("API_TOKEN", "t0k3n");

    var config: Config = .init(testing.allocator);
    defer config.deinit();
    config.useEnv(&environ);
    try config.addSecretProvider("vault", .{ .fetch = fakeVault });
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    try source.writer.print(
        \\token = "${{secret:env:API_TOKEN}}"
        \\[db]
        \\password = '${{secret:file:{s}/db-password}}'
        \\url = "postgres://app:${{secret:vault:db}}@host"
        \\
    , .{base});
    try tmp.dir.writeFile(io, .{ .sub_path = "app.toml", .data = source.written() });
    try config.loadFile(io, tmp.dir, "app.toml", null, null);
    try testing.expectEqualStrings("t0k3n", (try config.get("token")).?.string);
    try testing.expectEqualStrings("hunter2", (try config.get("db.password")).?.string);
    const url = (try config.get("db.url")).?.string;
    try testing.expectEqualStrings("postgres://app:s3cret@host", url);
    try testing.expect(config.isSecret("db.url"));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try config.write(&out.writer, .json, .{});
    try testing.expect(std.mem.indexOf(u8, out.written(), "hunter2") == null);

    try tmp.dir.writeFile(io, .{ .sub_path = "bad.toml", .data = "x = \"${secret:env:NOPE}\"\n" });
    var diag: Diagnostic = .{};
    const failed = config.loadFile(io, tmp.dir, "bad.toml", null, &diag);
    try testing.expectError(error.SecretNotFound, failed);
    try testing.expectEqualStrings("x", diag.key);
    try testing.expectEqualStrings("no secret ${secret:env:NOPE}", diag.message);
}

fn fakeVault(_: ?*anyopaque, _: Io, _: Allocator, name: []const u8) anyerror!?[]const u8 {
    return if (std.mem.eql(u8, name, "db")) "s3cret" else null;
}

test "includes load first, relative to the including file, and cycles are errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "conf/shared");
    try tmp.dir.writeFile(io, .{
        .sub_path = "conf/app.toml",
        .data = "include = [\"shared/base.yaml\", \"local.json\"]\nport = 3\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "conf/shared/base.yaml",
        .data = "port: 1\nname: base\nhost: h\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "conf/local.json", .data = "{\"name\": \"local\"}" });

    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.useIncludes("include");
    try config.loadFile(io, tmp.dir, "conf/app.toml", null, null);
    try testing.expectEqual(3, (try config.get("port")).?.int);
    try testing.expectEqualStrings("local", (try config.get("name")).?.string);
    try testing.expectEqualStrings("conf/shared/base.yaml", (try config.explain("host")).?.source);
    try testing.expectEqual(null, try config.get("include"));

    try tmp.dir.writeFile(io, .{ .sub_path = "a.toml", .data = "include = \"b.toml\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.toml", .data = "include = \"a.toml\"\n" });
    var diag: Diagnostic = .{};
    const cycle = config.loadFile(io, tmp.dir, "a.toml", null, &diag);
    try testing.expectError(error.IncludeCycle, cycle);
    try testing.expectEqualStrings("a.toml -> b.toml -> a.toml", diag.message);

    // A missing include loads nothing of its tree.
    const c = "include = [\"d.toml\", \"gone.toml\"]\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "c.toml", .data = c });
    try tmp.dir.writeFile(io, .{ .sub_path = "d.toml", .data = "from_d = 1\n" });
    try testing.expectError(error.FileNotFound, config.loadFile(io, tmp.dir, "c.toml", null, null));
    try testing.expectEqual(null, try config.get("from_d"));
}

test "decode errors and warnings point at the file and line that set the key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{
        .sub_path = "app.toml",
        .data = "include = \"base.yaml\"\n\n[server]\nport = 70000\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "base.yaml", .data = "name: x\nold_level: 3\n" });
    const Settings = struct {
        name: []const u8,
        level: u8 = 0,
        server: struct { port: u16 = 80, host: []const u8 } = .{ .host = "" },
        pub const meta = .{ .level = .{ .renamed_from = "old_level" } };
    };
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.useIncludes("include");
    try config.loadFile(io, tmp.dir, "app.toml", null, null);

    var diag: Diagnostic = .{};
    var errors: std.ArrayList(Diagnostic) = .empty;
    var warnings: std.ArrayList(Diagnostic) = .empty;
    const options: decoding.Options = .{ .errors = &errors, .warnings = &warnings };
    try testing.expectError(error.InvalidValue, config.decode(Settings, options, &diag));
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{diag});
    try testing.expectStringStartsWith(w.buffered(), "app.toml:4:8: server.port: ");
    try diag.writeSnippet(&w, config.sourceText("app.toml").?);
    try testing.expectStringEndsWith(w.buffered(), "  4 | port = 70000\n    |        ^\n");
    // A missing key points at its table; one from an included file at that file.
    try testing.expectEqual(2, errors.items.len);
    try testing.expectEqualStrings("server.host", errors.items[1].key);
    try testing.expectEqualStrings("app.toml", errors.items[1].file);
    try testing.expectEqual(3, errors.items[1].line);
    try testing.expectEqual(1, warnings.items.len);
    try testing.expectEqualStrings("base.yaml", warnings.items[0].file);
    try testing.expectEqual(2, warnings.items[0].line);

    // Set elsewhere than a file: no position.
    try config.set("server.port", "not a number");
    diag = .{};
    try testing.expectError(error.InvalidValue, config.decode(Settings, .{}, &diag));
    try testing.expectEqualStrings("server.port", diag.key);
    try testing.expectEqualStrings("", diag.file);
}

test "changed sees a file or an included file change, and reload settles it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "app.toml", .data = "include = \"a.toml\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.toml", .data = "a = 1\n" });
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.useIncludes("include");
    try config.loadFile(io, tmp.dir, "app.toml", null, null);
    try config.loadSource("given", "given = true\n", .toml, null);
    try testing.expect(!config.changed(io));

    // Sizes differ, so the check does not lean on the file system's clock resolution.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.toml", .data = "a = 22\n" });
    try testing.expect(config.changed(io));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try config.reload(io, arena.allocator(), null);
    try testing.expect(!config.changed(io));
    try testing.expectEqual(22, (try config.get("a")).?.int);

    try tmp.dir.deleteFile(io, "a.toml");
    try testing.expect(config.changed(io));
}

test "reload follows includes as they are now" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "app.toml", .data = "include = \"a.toml\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.toml", .data = "from_a = 1\nshared = \"a\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.toml", .data = "from_b = 2\nshared = \"b\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.toml", .data = "include = \"c.toml\"\n" });

    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.useIncludes("include");
    try config.loadFile(io, tmp.dir, "app.toml", null, null);
    try config.loadSource("given", "given = true\n", .toml, null);
    try testing.expectEqual(1, (try config.get("from_a")).?.int);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The included file changes: dropped, and another added.
    try tmp.dir.writeFile(io, .{ .sub_path = "app.toml", .data = "include = [\"b.toml\"]\n" });
    var changes = try config.reload(io, arena.allocator(), null);
    try testing.expectEqual(3, changes.len);
    try testing.expectEqual(null, try config.get("from_a"));
    try testing.expectEqual(2, (try config.get("from_b")).?.int);
    try testing.expectEqualStrings("b.toml", (try config.explain("shared")).?.source);
    try testing.expectEqual(true, (try config.get("given")).?.bool);

    // No include at all any more.
    try tmp.dir.writeFile(io, .{ .sub_path = "app.toml", .data = "own = 3\n" });
    changes = try config.reload(io, arena.allocator(), null);
    try testing.expectEqual(null, try config.get("from_b"));
    try testing.expectEqual(3, (try config.get("own")).?.int);

    // A reload that fails changes nothing: here, an include cycle.
    try tmp.dir.writeFile(io, .{ .sub_path = "app.toml", .data = "include = \"c.toml\"\n" });
    var diag: Diagnostic = .{};
    try testing.expectError(error.IncludeCycle, config.reload(io, arena.allocator(), &diag));
    try testing.expectEqual(3, (try config.get("own")).?.int);
    try testing.expectEqual(true, (try config.get("given")).?.bool);
}

const CountingSource = struct {
    calls: u32 = 0,

    fn load(context: ?*anyopaque, _: Io, arena: Allocator, diag: ?*Diagnostic) anyerror!Value {
        const self: *CountingSource = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.calls == 3) {
            if (diag) |d| d.message = "store unreachable";
            return error.ConnectionRefused;
        }
        var tree: Value = .empty_table;
        try tree.put(arena, "remote.calls", .{ .int = self.calls });
        return tree;
    }
};

test "a Source loads like a file, and reload calls it again" {
    var counter: CountingSource = .{};
    const source: Source = .{
        .context = &counter,
        .name = "store:app",
        .load = CountingSource.load,
    };
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.loadFrom(testing.io, source, null);
    try testing.expectEqual(1, (try config.get("remote.calls")).?.int);
    try testing.expectEqualStrings("store:app", (try config.explain("remote.calls")).?.source);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const changes = try config.reload(testing.io, arena.allocator(), null);
    try testing.expectEqual(1, changes.len);
    try testing.expectEqual(2, (try config.get("remote.calls")).?.int);

    var diag: Diagnostic = .{};
    const failed = config.reload(testing.io, arena.allocator(), &diag);
    try testing.expectError(error.SourceFailed, failed);
    try testing.expectEqualStrings("store:app", diag.key);
    try testing.expectEqualStrings("ConnectionRefused: store unreachable", diag.message);
    try testing.expectEqual(2, (try config.get("remote.calls")).?.int);
}

test "an encrypted file loads with the passphrase, and its keys are secret" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const envelope = try encrypted.encrypt(
        arena.allocator(),
        io,
        "[db]\npassword = \"hunter2\"\n",
        "pass",
        .toml,
        .{ .t = 1, .m = 64, .p = 1 },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "secrets.toml.enc", .data = envelope });

    var config: Config = .init(testing.allocator);
    defer config.deinit();
    const name = "secrets.toml.enc";
    const locked = config.loadFile(io, tmp.dir, name, null, null);
    try testing.expectError(error.PassphraseRequired, locked);
    config.usePassphrase("nope");
    try testing.expectError(error.WrongPassphrase, config.loadFile(io, tmp.dir, name, null, null));
    config.usePassphrase("pass");
    try config.loadFile(io, tmp.dir, "secrets.toml.enc", null, null);
    try testing.expectEqualStrings("hunter2", (try config.get("db.password")).?.string);
    try testing.expect(config.isSecret("db.password"));
}

test "set patches the effective tree exactly as a rebuild would" {
    var incremental: Config = .init(testing.allocator);
    defer incremental.deinit();
    var rebuilt: Config = .init(testing.allocator);
    defer rebuilt.deinit();
    const source =
        \\{"a": {"b": 1, "c": [1, 2]}, "d": "x", "list": [{"k": 1}]}
    ;
    try incremental.loadSource("s.json", source, .json, null);
    try rebuilt.loadSource("s.json", source, .json, null);
    var prng: std.Random.DefaultPrng = .init(0x1ce);
    const random = prng.random();
    const candidates = [_][]const u8{ "a", "a.b", "a.c", "a.e.f", "d", "d.x", "list.0.k", "new" };
    for (0..400) |_| {
        const key = candidates[random.uintLessThan(usize, candidates.len)];
        const value: i64 = random.int(i8);
        _ = try incremental.resolve();
        incremental.set(key, value) catch |err| {
            // Setting `d.x` once `d` is a number fails the same either way.
            try testing.expectError(err, rebuilt.set(key, value));
            continue;
        };
        try rebuilt.set(key, value);
        rebuilt.invalidate();
        const want = try rebuilt.resolve();
        const got = try incremental.resolve();
        try testing.expect(want.eql(got));
        for (try rebuilt.keys()) |leaf| {
            const expected = (try rebuilt.explain(leaf)).?;
            const actual = (try incremental.explain(leaf)).?;
            try testing.expectEqual(expected.layer, actual.layer);
        }
    }
}

test "with references, set patches exactly as a rebuild would" {
    var incremental: Config = .init(testing.allocator);
    defer incremental.deinit();
    var rebuilt: Config = .init(testing.allocator);
    defer rebuilt.deinit();
    const source =
        \\{"host": "h", "port": 1, "url": "http://${host}:${port}/${path}",
        \\ "path": "p", "server": {"name": "${host}-${port}"}, "label": "${server.name}!",
        \\ "literal": "$${host}", "list": ["${host}"]}
    ;
    for ([_]*Config{ &incremental, &rebuilt }) |config| {
        config.useReferences();
        try config.loadSource("s.json", source, .json, null);
    }
    var prng: std.Random.DefaultPrng = .init(0x2ef);
    const random = prng.random();
    const targets = [_][]const u8{ "host", "port", "path", "server.name", "label", "url", "new" };
    const values = [_][]const u8{ "x", "${new}", "${path}/${host}", "$${port}", "${label}", "7" };
    var patched: usize = 0;
    for (0..400) |_| {
        const key = targets[random.uintLessThan(usize, targets.len)];
        const value = values[random.uintLessThan(usize, values.len)];
        _ = try incremental.resolve();
        try incremental.set(key, value);
        if (incremental.effective != null) patched += 1;
        try rebuilt.set(key, value);
        rebuilt.invalidate();
        const want = try rebuilt.resolve();
        const got = try incremental.resolve();
        try testing.expect(want.eql(got));
        const want_problem = rebuilt.checkReferences(null);
        const got_problem = incremental.checkReferences(null);
        try testing.expectEqual(want_problem, got_problem);
    }
    // Most sets avoid a rebuild; a regression to "always rebuild" must fail.
    try testing.expect(patched > 100);
}

test "loadReader streams JSON and YAML and reads other formats whole" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    var json_reader: Io.Reader = .fixed("{\"a\": {\"b\": 1}}");
    try config.loadReader("stdin", &json_reader, .json, null);
    var toml_reader: Io.Reader = .fixed("c = 2\n");
    try config.loadReader("pipe", &toml_reader, .toml, null);
    try testing.expectEqual(1, (try config.get("a.b")).?.int);
    try testing.expectEqualStrings("pipe", (try config.explain("c")).?.source);
    var bad: Io.Reader = .fixed("[1]");
    try testing.expectError(error.SyntaxError, config.loadReader("x", &bad, .json, null));
    var yaml_reader: Io.Reader = .fixed("d:\n  e: 3\nf: [1, 2]\n");
    try config.loadReader("yaml", &yaml_reader, .yaml, null);
    try testing.expectEqual(3, (try config.get("d.e")).?.int);
    var list: Io.Reader = .fixed("- 1\n");
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, config.loadReader("y", &list, .yaml, &diag));
}

test "views read a section with relative keys, and decode it" {
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.loadSource(
        "app.toml",
        "[db]\nhost = \"h\"\nport = 70000\n[db.pool]\nsize = 4\n",
        .toml,
        null,
    );
    const db = config.view("db");
    try testing.expectEqualStrings("h", (try db.getString("host")).?);
    const pool = try db.view("pool");
    try testing.expectEqual(4, (try pool.getInt(u8, "size")).?);
    const Db = struct { host: []const u8, port: u16 };
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, db.decode(Db, .{}, &diag));
    try testing.expectEqualStrings("db.port", diag.key);
    try testing.expectEqualStrings("app.toml", diag.file);
    try testing.expectEqual(3, diag.line);
    const Pool = struct { size: u8 = 1, idle: u8 = 2 };
    const decoded = try pool.decode(Pool, .{}, null);
    try testing.expectEqual(4, decoded.size);
    try testing.expectEqual(2, (try config.view("absent").decode(Pool, .{}, null)).idle);
}

test "resolvers expand ${name:argument} without making the key secret" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{
        .sub_path = "app.toml",
        .data = "greeting = \"hi ${upper:there}, ${ref}\"\nother = \"${missing:x}\"\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.toml", .data = "g = \"${upper:abc}${x}\"\n" });
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    try config.addResolver("upper", .{ .fetch = struct {
        fn fetch(_: ?*anyopaque, _: Io, arena: Allocator, name: []const u8) anyerror!?[]const u8 {
            const out = try arena.alloc(u8, name.len);
            return std.ascii.upperString(out, name);
        }
    }.fetch });
    try config.loadFile(io, tmp.dir, "ok.toml", null, null);
    try testing.expectEqualStrings("ABC${x}", (try config.getString("g")).?);
    try testing.expect(!config.isSecret("g"));
    try config.addResolver("missing", .{ .fetch = struct {
        fn fetch(_: ?*anyopaque, _: Io, _: Allocator, _: []const u8) anyerror!?[]const u8 {
            return null;
        }
    }.fetch });
    var diag: Diagnostic = .{};
    try testing.expectError(
        error.SecretNotFound,
        config.loadFile(io, tmp.dir, "app.toml", null, &diag),
    );
    try testing.expectEqualStrings("other", diag.key);
    try testing.expectEqualStrings("nothing for ${missing:x}", diag.message);
}

test "findFile looks upward first, when asked, then in dirs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/.toolrc.json", .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const start = try std.fs.path.join(testing.allocator, &.{ root, "a", "b" });
    defer testing.allocator.free(start);
    var config: Config = .init(testing.allocator);
    defer config.deinit();
    const found = try config.findFile(io, .{ .name = ".toolrc", .upward = true, .start = start });
    // In the separator `start` was written with.
    const sep = std.fs.path.sep_str;
    try testing.expect(std.mem.endsWith(u8, found.?, sep ++ "a" ++ sep ++ ".toolrc.json"));
    // Not upward: only `dirs`.
    try testing.expectEqual(
        null,
        try config.findFile(io, .{ .name = ".toolrc", .dirs = &.{start} }),
    );
    // Stops at $HOME.
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", start);
    config.useEnv(&environ);
    try testing.expectEqual(
        null,
        try config.findFile(io, .{ .name = ".toolrc", .upward = true, .start = start }),
    );
}

test "variants load over the base file, in order, and missing ones are skipped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "conf");
    try tmp.dir.writeFile(io, .{ .sub_path = "conf/app.toml", .data = "port = 1\nname = \"a\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "conf/app.production.toml", .data = "port = 2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "conf/app.local.toml", .data = "name = \"me\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "A=1\nB=1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env.local", .data = "B=2\n" });

    var config: Config = .init(testing.allocator);
    defer config.deinit();
    const variants: []const []const u8 = &.{ "production", "staging", "local" };
    const found = try config.loadVariants(io, tmp.dir, "conf/app.toml", variants, null, null);
    try testing.expectEqual(2, found);
    try testing.expectEqual(2, (try config.get("port")).?.int);
    try testing.expectEqualStrings("me", (try config.get("name")).?.string);
    const origin = (try config.explain("port")).?;
    try testing.expect(std.mem.endsWith(u8, origin.source, "app.production.toml"));

    const local: []const []const u8 = &.{"local"};
    try testing.expectEqual(1, try config.loadVariants(io, tmp.dir, ".env", local, null, null));
    // dotenv keys are lowercased.
    try testing.expectEqualStrings("2", (try config.get("b")).?.string);
    try testing.expectError(
        error.FileNotFound,
        config.loadVariants(io, tmp.dir, "nope.toml", local, null, null),
    );
}

test variantPath {
    const a = testing.allocator;
    const cases = [_][3][]const u8{
        .{ "app.toml", "local", "app.local.toml" },
        .{ "conf/app.yaml", "prod", "conf/app.prod.yaml" },
        .{ ".env", "local", ".env.local" },
        .{ "x/.env.production", "local", "x/.env.production.local" },
    };
    for (cases) |case| {
        const got = try variantPath(a, case[0], case[1]);
        defer a.free(got);
        try testing.expectEqualStrings(case[2], got);
    }
}
