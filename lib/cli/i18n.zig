//! Minimal message translation: locale detection, dictionaries and `{key}`
//! interpolation.
//!
//! This file **is** the type: the file's own scope is `I18n`, so a consumer writes
//! `const I18n = @import("i18n.zig");`. See the file-layout rule in
//! `.agents/AGENTS.md`.
//!
//! `Locale` stays a declaration inside, because a translator's whole job is
//! resolving against one - one subject, not two.

const std = @import("std");

const Self = @This();

/// A parsed language tag. `territory` is null when the tag carried none.
pub const Locale = struct {
    lang: []const u8,
    territory: ?[]const u8 = null,

    /// Parses tags like `en`, `en_US`, `en-US`, and strips `.UTF-8` / `@euro`.
    pub fn parse(tag: []const u8) Locale {
        var clean = tag;
        // Strip encoding like .UTF-8 or @euro
        if (std.mem.indexOf(u8, clean, ".")) |dot| {
            clean = clean[0..dot];
        }
        if (std.mem.indexOf(u8, clean, "@")) |at| {
            clean = clean[0..at];
        }

        if (std.mem.indexOf(u8, clean, "_")) |under| {
            return .{
                .lang = clean[0..under],
                .territory = clean[under + 1 ..],
            };
        } else if (std.mem.indexOf(u8, clean, "-")) |hyphen| {
            return .{
                .lang = clean[0..hyphen],
                .territory = clean[hyphen + 1 ..],
            };
        }
        return .{ .lang = clean };
    }
};

allocator: std.mem.Allocator,
current_locale: Locale,
translations: std.StringHashMap(std.StringHashMap([]const u8)),

pub fn init(allocator: std.mem.Allocator, default_lang: []const u8) Self {
    return .{
        .allocator = allocator,
        .current_locale = Locale.parse(default_lang),
        .translations = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.translations.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit();
    }
    self.translations.deinit();
}

/// Detect locale from environment (LC_ALL, LC_MESSAGES, LANG).
pub fn detectLocale(env_map: *std.process.Environ.Map) Locale {
    if (env_map.get("LC_ALL")) |val| {
        if (val.len > 0) return Locale.parse(val);
    }
    if (env_map.get("LC_MESSAGES")) |val| {
        if (val.len > 0) return Locale.parse(val);
    }
    if (env_map.get("LANG")) |val| {
        if (val.len > 0) return Locale.parse(val);
    }
    return .{ .lang = "en", .territory = "US" };
}

pub fn setLocale(self: *Self, locale_tag: []const u8) void {
    self.current_locale = Locale.parse(locale_tag);
}

/// Add a translation dictionary for a language code (e.g., "es", "fr", "en").
pub fn addTranslations(self: *Self, lang: []const u8, entries: []const struct { []const u8, []const u8 }) !void {
    var gop = try self.translations.getOrPut(lang);
    if (!gop.found_existing) {
        gop.value_ptr.* = std.StringHashMap([]const u8).init(self.allocator);
    }
    for (entries) |pair| {
        try gop.value_ptr.put(pair[0], pair[1]);
    }
}

/// Translates a key for current locale with fallback to English, returning the format string.
pub fn t(self: *const Self, key: []const u8) []const u8 {
    if (self.translations.get(self.current_locale.lang)) |dict| {
        if (dict.get(key)) |val| return val;
    }
    // Fallback to "en"
    if (!std.mem.eql(u8, self.current_locale.lang, "en")) {
        if (self.translations.get("en")) |dict| {
            if (dict.get(key)) |val| return val;
        }
    }
    return key;
}

/// Translates and interpolates named parameters `{key}` into a buffer or writer.
pub fn format(self: *const Self, writer: anytype, key: []const u8, params: anytype) !void {
    const tmpl = self.t(key);
    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] == '{') {
            if (std.mem.indexOfScalar(u8, tmpl[i + 1 ..], '}')) |close_idx| {
                const param_name = tmpl[i + 1 .. i + 1 + close_idx];
                var replaced = false;

                inline for (std.meta.fields(@TypeOf(params))) |field| {
                    if (std.mem.eql(u8, field.name, param_name)) {
                        const val = @field(params, field.name);
                        switch (@typeInfo(field.type)) {
                            .pointer => |p| {
                                if (p.child == u8) {
                                    try writer.writeAll(val);
                                } else if (@typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) {
                                    try writer.writeAll(val);
                                } else {
                                    try writer.print("{any}", .{val});
                                }
                            },
                            else => {
                                try writer.print("{any}", .{val});
                            },
                        }
                        replaced = true;
                        break;
                    }
                }

                if (replaced) {
                    i += 1 + close_idx + 1;
                    continue;
                }
            }
        }
        try writer.writeByte(tmpl[i]);
        i += 1;
    }
}

test "Locale.parse handles the tag forms and strips encodings" {
    const en = Self.Locale.parse("en");
    try std.testing.expectEqualStrings("en", en.lang);
    try std.testing.expect(en.territory == null);

    const us = Self.Locale.parse("en_US.UTF-8");
    try std.testing.expectEqualStrings("en", us.lang);
    try std.testing.expectEqualStrings("US", us.territory.?);

    const hyphen = Self.Locale.parse("pt-BR");
    try std.testing.expectEqualStrings("pt", hyphen.lang);
    try std.testing.expectEqualStrings("BR", hyphen.territory.?);

    const euro = Self.Locale.parse("de_DE@euro");
    try std.testing.expectEqualStrings("de", euro.lang);
    try std.testing.expectEqualStrings("DE", euro.territory.?);
}

test "translation falls back to English and then to the key itself" {
    var tr = Self.init(std.testing.allocator, "es");
    defer tr.deinit();

    try tr.addTranslations("es", &.{.{ "greeting", "Hola" }});
    try tr.addTranslations("en", &.{ .{ "greeting", "Hello" }, .{ "only_en", "English only" } });

    try std.testing.expectEqualStrings("Hola", tr.t("greeting"));
    // Not in "es", so it falls back to "en".
    try std.testing.expectEqualStrings("English only", tr.t("only_en"));
    // In neither, so the key is returned unchanged.
    try std.testing.expectEqualStrings("absent", tr.t("absent"));

    tr.setLocale("fr");
    // "fr" has no dictionary at all, so "en" still answers.
    try std.testing.expectEqualStrings("Hello", tr.t("greeting"));
}

test "format interpolates named parameters" {
    var tr = Self.init(std.testing.allocator, "en");
    defer tr.deinit();
    try tr.addTranslations("en", &.{.{ "greet", "Hello {name}, you have {count}" }});

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tr.format(&w, "greet", .{ .name = "Ada", .count = 3 });

    try std.testing.expectEqualStrings("Hello Ada, you have 3", w.buffered());
}
