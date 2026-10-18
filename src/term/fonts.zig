//! Finding fonts on this machine by family name, as a terminal does when told to use
//! "JetBrains Mono": the system's and the user's font directories (and, under WSL,
//! Windows'), their TrueType files read only as far as their names. For `raster`, so
//! `termancy record` and `freeze` draw in a font the user has, with fallbacks for what it
//! lacks (CJK, symbols).
//!
//! ```zig
//! var set = try term.fonts.load(gpa, io, environ, "JetBrains Mono");
//! defer set.deinit();
//! var painter: term.raster.Painter = .init(gpa, set.fonts(), .{});
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const TrueType = @import("TrueType.zig");
const raster = @import("raster.zig");

/// A font file and the face in it.
pub const Face = struct {
    path: []const u8,
    index: u32,
    family: []const u8,
    style: []const u8,
};

/// Monospace families tried, in order, when none is named or the named one is missing.
pub const default_families = [_][]const u8{
    "JetBrains Mono", "Cascadia Mono",    "Cascadia Code",   "SF Mono",     "Menlo",
    "Fira Code",      "DejaVu Sans Mono", "Hack",            "Consolas",    "Liberation Mono",
    "Noto Sans Mono", "Ubuntu Mono",      "Source Code Pro", "Courier New",
};

/// Families tried for characters the main font lacks: wide scripts and symbols.
pub const fallback_families = [_][]const u8{
    "Noto Sans Mono CJK SC", "Noto Sans CJK SC",    "Sarasa Mono SC",  "MS Gothic",
    "Hiragino Sans",         "PingFang SC",         "Microsoft YaHei", "Malgun Gothic",
    "Segoe UI Symbol",       "Noto Sans Symbols 2", "DejaVu Sans",     "Symbola",
    "Apple Symbols",         "Segoe UI",
};

/// The directories fonts live in here.
pub fn directories(
    arena: Allocator,
    environ: *const std.process.Environ.Map,
) Allocator.Error![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    const home = environ.get("HOME") orelse environ.get("USERPROFILE") orelse "";
    switch (builtin.os.tag) {
        .windows => {
            const windir = environ.get("WINDIR") orelse "C:\\Windows";
            try dirs.append(arena, try std.fs.path.join(arena, &.{ windir, "Fonts" }));
            if (environ.get("LOCALAPPDATA")) |local| {
                try dirs.append(
                    arena,
                    try std.fs.path.join(arena, &.{ local, "Microsoft", "Windows", "Fonts" }),
                );
            }
        },
        .macos => {
            if (home.len > 0) try dirs.append(
                arena,
                try std.fs.path.join(arena, &.{ home, "Library/Fonts" }),
            );
            try dirs.appendSlice(arena, &.{
                "/Library/Fonts",
                "/System/Library/Fonts",
                "/System/Library/Fonts/Supplemental",
            });
        },
        else => {
            if (environ.get("XDG_DATA_HOME")) |data| try dirs.append(
                arena,
                try std.fs.path.join(arena, &.{ data, "fonts" }),
            );
            if (home.len > 0) {
                try dirs.append(
                    arena,
                    try std.fs.path.join(arena, &.{ home, ".local/share/fonts" }),
                );
                try dirs.append(arena, try std.fs.path.join(arena, &.{ home, ".fonts" }));
            }
            try dirs.appendSlice(arena, &.{ "/usr/share/fonts", "/usr/local/share/fonts" });
            // Under WSL, the Windows fonts too.
            try dirs.append(arena, "/mnt/c/Windows/Fonts");
        },
    }
    return dirs.items;
}

/// Every TrueType face under `dirs` (recursively), by its names. Fonts that cannot be read
/// are skipped.
pub fn scan(arena: Allocator, io: Io, dirs: []const []const u8) Allocator.Error![]const Face {
    var faces: std.ArrayList(Face) = .empty;
    for (dirs) |root| {
        var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = dir.walk(arena) catch continue;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            const ext = std.fs.path.extension(entry.basename);
            const font_file = std.ascii.eqlIgnoreCase(ext, ".ttf") or
                std.ascii.eqlIgnoreCase(ext, ".ttc");
            if (!font_file) continue;
            const path = try std.fs.path.join(arena, &.{ root, entry.path });
            try readFaces(arena, io, path, &faces);
        }
    }
    return faces.items;
}

/// The faces in one file, by reading its table directories and `name` tables only.
fn readFaces(
    arena: Allocator,
    io: Io,
    path: []const u8,
    faces: *std.ArrayList(Face),
) Allocator.Error!void {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    var header: [4096]u8 = undefined;
    const n = file.readPositionalAll(io, &header, 0) catch return;
    if (n < 12) return;
    const head = header[0..n];
    const count: u32 = if (std.mem.eql(u8, head[0..4], "ttcf"))
        @min(std.mem.readInt(u32, head[8..12], .big), 64)
    else
        1;
    for (0..count) |face| {
        const location = TrueType.findTable(head, @intCast(face), "name") orelse continue;
        if (location[1] > 1 << 20) continue;
        const table = try arena.alloc(u8, location[1]);
        const got = file.readPositionalAll(io, table, location[0]) catch continue;
        var names_buffer: [512]u8 = undefined;
        const names = TrueType.readNames(table[0..got], &names_buffer) orelse continue;
        try faces.append(arena, .{
            .path = path,
            .index = @intCast(face),
            .family = try arena.dupe(u8, names.family),
            .style = try arena.dupe(u8, names.style),
        });
    }
}

/// The face of `family` in `style` (`Regular`, `Bold`, `Italic`, `Bold Italic`, with
/// `Oblique` as italic), ignoring case and spaces.
pub fn find(faces: []const Face, family: []const u8, style: Style) ?Face {
    var best: ?Face = null;
    var best_rank: u8 = 0;
    for (faces) |face| {
        if (!sameName(face.family, family)) continue;
        const rank = styleRank(face.style, style);
        if (rank > best_rank) {
            best = face;
            best_rank = rank;
        }
    }
    return best;
}

/// A face of a family.
pub const Style = enum { regular, bold, italic, bold_italic };

/// How well a face's style name matches `style`: 0 not at all.
fn styleRank(name: []const u8, style: Style) u8 {
    const bold = containsWord(name, "bold");
    const italic = containsWord(name, "italic") or containsWord(name, "oblique");
    const other_weight = !bold and (containsWord(name, "light") or containsWord(name, "thin") or
        containsWord(name, "medium") or containsWord(name, "semibold") or
        containsWord(name, "black") or containsWord(name, "extra"));
    const want_bold = style == .bold or style == .bold_italic;
    const want_italic = style == .italic or style == .bold_italic;
    if (bold != want_bold or italic != want_italic) return 0;
    if (other_weight) return 1;
    // "Bold" beats "ExtraBold" and "SemiBold".
    if (containsWord(name, "semi") or containsWord(name, "extra")) return 2;
    return 3;
}

fn containsWord(haystack: []const u8, word: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, word) != null;
}

/// Whether two family names are the same, ignoring case, spaces, and dashes.
pub fn sameName(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and (a[i] == ' ' or a[i] == '-')) i += 1;
        while (j < b.len and (b[j] == ' ' or b[j] == '-')) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

/// Fonts loaded for drawing: the files' bytes and the parsed faces.
pub const Set = struct {
    arena: std.heap.ArenaAllocator,
    regular: TrueType,
    bold: ?TrueType = null,
    italic: ?TrueType = null,
    bold_italic: ?TrueType = null,
    fallbacks: []TrueType = &.{},
    /// The family found.
    family: []const u8 = "",

    /// Frees the fonts.
    pub fn deinit(s: *Set) void {
        s.arena.deinit();
    }

    /// The set as `raster` draws with it.
    pub fn fonts(s: *const Set) raster.Fonts {
        return .{
            .regular = s.regular,
            .bold = s.bold,
            .italic = s.italic,
            .bold_italic = s.bold_italic,
            .fallbacks = s.fallbacks,
        };
    }
};

/// What finding and loading a family can fail with.
pub const LoadError = error{ FontNotFound, UnsupportedOutlines } ||
    Allocator.Error || Io.Cancelable;

/// Loads `family` (or, when empty, the first of `default_families` found) in its four
/// styles, with fallbacks. `family` may also be a path to a `.ttf` or `.ttc` file.
pub fn load(
    gpa: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    family: []const u8,
) LoadError!Set {
    var set: Set = .{ .arena = .init(gpa), .regular = undefined };
    errdefer set.arena.deinit();
    const arena = set.arena.allocator();
    if (std.mem.endsWith(u8, family, ".ttf") or std.mem.endsWith(u8, family, ".ttc")) {
        set.regular = try loadFile(arena, io, family, 0) orelse return error.FontNotFound;
        set.family = family;
    } else {
        const faces = try scan(arena, io, try directories(arena, environ));
        const chosen = blk: {
            if (family.len > 0) {
                if (find(faces, family, .regular)) |face| break :blk face;
                return error.FontNotFound;
            }
            for (default_families) |name| if (find(faces, name, .regular)) |face| break :blk face;
            // Any monospace-looking face at all.
            for (faces) |face| {
                if (containsWord(face.family, "mono") and
                    styleRank(face.style, .regular) > 0) break :blk face;
            }
            return error.FontNotFound;
        };
        set.family = chosen.family;
        set.regular = try loadFile(arena, io, chosen.path, chosen.index) orelse
            return error.FontNotFound;
        if (find(faces, chosen.family, .bold)) |f| {
            set.bold = try loadFile(arena, io, f.path, f.index);
        }
        if (find(faces, chosen.family, .italic)) |f| {
            set.italic = try loadFile(arena, io, f.path, f.index);
        }
        if (find(faces, chosen.family, .bold_italic)) |f| {
            set.bold_italic = try loadFile(arena, io, f.path, f.index);
        }
        var fallbacks: std.ArrayList(TrueType) = .empty;
        for (fallback_families) |name| {
            const f = find(faces, name, .regular) orelse continue;
            if (try loadFile(arena, io, f.path, f.index)) |font| try fallbacks.append(arena, font);
            if (fallbacks.items.len == 4) break;
        }
        set.fallbacks = fallbacks.items;
    }
    return set;
}

fn loadFile(arena: Allocator, io: Io, path: []const u8, face: u32) LoadError!?TrueType {
    const bytes = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(64 << 20),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return null,
    };
    return TrueType.init(bytes, face) catch |err| switch (err) {
        error.UnsupportedOutlines => return null,
        error.InvalidFont => return null,
    };
}

const testing = std.testing;

test sameName {
    try testing.expect(sameName("JetBrains Mono", "jetbrainsmono"));
    try testing.expect(sameName("DejaVu Sans-Mono", "dejavu sans mono"));
    try testing.expect(!sameName("Menlo", "Menlo Bold"));
}

test styleRank {
    try testing.expect(styleRank("Regular", .regular) == 3);
    try testing.expect(styleRank("Bold", .bold) == 3);
    try testing.expect(styleRank("ExtraBold", .bold) == 2);
    try testing.expect(styleRank("Bold Oblique", .bold_italic) == 3);
    try testing.expect(styleRank("Italic", .regular) == 0);
    try testing.expect(styleRank("Light", .regular) == 1);
}

test "the machine's fonts can be found and loaded" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var set = load(testing.allocator, testing.io, &environ, "") catch |err| switch (err) {
        error.FontNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer set.deinit();
    try testing.expect(set.family.len > 0);
    try testing.expect(set.regular.has('A'));
}
