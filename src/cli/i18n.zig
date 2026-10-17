//! Translation, as gettext does it: the English text is the key, so nothing needs an
//! identifier, and anything not translated stays English.
//!
//! ```zig
//! const german: cli.i18n.Translation = .{
//!     .locale = "de",
//!     .messages = &cli.i18n.messages.german, // the library's own sentences
//!     .strings = &.{
//!         .{ "Start the server", "Den Server starten" },     // a summary, flag help, ...
//!         .{ "Hello, {0}!", "Hallo, {0}!" },                  // for ctx.tr
//!         .{ "Deleted {0} files", "{0} Datei gelöscht|{0} Dateien gelöscht" }, // ctx.plural
//!     },
//! };
//! const app: cli.App = .{ .root = &root, .translations = &.{german} };
//! ```
//!
//! The locale comes from `App.locale`, else `LC_ALL`, `LC_MESSAGES`, or `LANG` (`de_DE.UTF-8`),
//! the first that is set; `C` and `POSIX` mean English. A translation for `pt_BR` is
//! preferred for `pt_BR`, then one for `pt`, then any other `pt` one.
//!
//! Help translates every summary, description, group heading, flag help, and example
//! found in `strings`. Handlers translate their own text with `ctx.tr`, `ctx.plural`, and
//! `ctx.translate`.
//! Templates mark arguments `{0}`, `{1}`, ... as `Messages` does. A plural's translation
//! holds its forms separated by `|`, in the order of the language's `PluralRule` (for
//! English and German, one and other; for Russian, one, few, and many).

const std = @import("std");
const Messages = @import("Messages.zig");

/// A language tag: `de`, `pt_BR`, `en-GB`, with any `.UTF-8` or `@euro` removed.
pub const Locale = struct {
    language: []const u8,
    territory: []const u8 = "",

    /// Reads `de`, `pt_BR`, `en-GB.UTF-8`.
    pub fn parse(tag: []const u8) Locale {
        var clean = tag;
        if (std.mem.indexOfAny(u8, clean, ".@")) |end| clean = clean[0..end];
        const split = std.mem.indexOfAny(u8, clean, "_-") orelse return .{ .language = clean };
        const rest = clean[split + 1 ..];
        const end = std.mem.indexOfAny(u8, rest, "_-") orelse rest.len;
        return .{ .language = clean[0..split], .territory = rest[0..end] };
    }

    fn sameLanguage(a: Locale, b: Locale) bool {
        return std.ascii.eqlIgnoreCase(a.language, b.language);
    }

    fn eql(a: Locale, b: Locale) bool {
        return a.sameLanguage(b) and std.ascii.eqlIgnoreCase(a.territory, b.territory);
    }
};

/// The user's locale from `LC_ALL`, `LC_MESSAGES`, or `LANG`; null when none is set or it
/// is `C` or `POSIX`.
pub fn detect(environ: *const std.process.Environ.Map) ?Locale {
    for ([_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
        const value = environ.get(name) orelse continue;
        if (value.len == 0) continue;
        const locale: Locale = .parse(value);
        if (std.mem.eql(u8, locale.language, "C") or std.mem.eql(u8, locale.language, "POSIX")) {
            return null;
        }
        return locale;
    }
    return null;
}

/// Which of a translation's plural forms fits `n`: an index into them.
pub const PluralRule = *const fn (n: u64) usize;

/// Plural rules for whole numbers, from CLDR.
pub const plural_rules = struct {
    /// Forms: one, other. English, German, Dutch, the Scandinavian languages, Italian,
    /// Spanish, Greek, Turkish, and most others.
    pub fn oneOther(n: u64) usize {
        return if (n == 1) 0 else 1;
    }
    /// Forms: one (0 and 1), other. French, Portuguese.
    pub fn zeroOneOther(n: u64) usize {
        return if (n <= 1) 0 else 1;
    }
    /// Forms: one, few, many. Russian, Ukrainian, Belarusian.
    pub fn eastSlavic(n: u64) usize {
        const ten = n % 10;
        const hundred = n % 100;
        if (ten == 1 and hundred != 11) return 0;
        if (ten >= 2 and ten <= 4 and (hundred < 12 or hundred > 14)) return 1;
        return 2;
    }
    /// Forms: one, few, many. Polish.
    pub fn polish(n: u64) usize {
        if (n == 1) return 0;
        const ten = n % 10;
        const hundred = n % 100;
        if (ten >= 2 and ten <= 4 and (hundred < 12 or hundred > 14)) return 1;
        return 2;
    }
    /// Forms: one, few, other. Czech, Slovak.
    pub fn czech(n: u64) usize {
        if (n == 1) return 0;
        if (n >= 2 and n <= 4) return 1;
        return 2;
    }
    /// One form. Chinese, Japanese, Korean, Vietnamese, Thai, Indonesian.
    pub fn none(_: u64) usize {
        return 0;
    }
};

/// The plural rule CLDR gives `language`, `oneOther` for languages not listed.
pub fn pluralRuleFor(language: []const u8) PluralRule {
    const table = [_]struct { []const []const u8, PluralRule }{
        .{ &.{ "fr", "pt" }, plural_rules.zeroOneOther },
        .{ &.{ "ru", "uk", "be" }, plural_rules.eastSlavic },
        .{ &.{"pl"}, plural_rules.polish },
        .{ &.{ "cs", "sk" }, plural_rules.czech },
        .{ &.{ "zh", "ja", "ko", "vi", "th", "id", "ms" }, plural_rules.none },
    };
    for (table) |row| for (row[0]) |name| {
        if (std.ascii.eqlIgnoreCase(name, language)) return row[1];
    };
    return plural_rules.oneOther;
}

/// One English text and its translation.
pub const Entry = struct { []const u8, []const u8 };

/// Everything translated into one locale.
pub const Translation = struct {
    /// The locale it is for: a language (`de`) or a language and territory (`pt_BR`).
    locale: []const u8,
    /// The library's own sentences; null keeps them English. See `messages` for some.
    messages: ?*const Messages = null,
    /// English text to translated text: command summaries, descriptions, groups, flag
    /// help, examples, and the app's own strings.
    strings: []const Entry = &.{},
    /// How plural forms are chosen; null takes the rule for the locale's language.
    plural_rule: ?PluralRule = null,

    /// `text` translated, or `text` when this translation does not have it.
    pub fn text(t: *const Translation, english: []const u8) []const u8 {
        for (t.strings) |entry| {
            if (std.mem.eql(u8, entry[0], english)) return entry[1];
        }
        return english;
    }

    /// The form of `other` (the English plural, the key) that fits `n`, or of `one`
    /// and `other` when not translated.
    pub fn plural(t: *const Translation, n: u64, one: []const u8, other: []const u8) []const u8 {
        const forms = t.text(other);
        if (forms.ptr == other.ptr) return if (n == 1) one else other;
        const rule = t.plural_rule orelse pluralRuleFor(Locale.parse(t.locale).language);
        var index = rule(n);
        var it = std.mem.splitScalar(u8, forms, '|');
        var last: []const u8 = forms;
        while (it.next()) |form| {
            last = form;
            if (index == 0) return form;
            index -= 1;
        }
        return last;
    }
};

/// `english` translated by `translation`, when there is one.
pub fn textIn(translation: ?*const Translation, english: []const u8) []const u8 {
    const t = translation orelse return english;
    return t.text(english);
}

/// The translation for `locale` among `translations`: same language and territory, else
/// the same language with no territory, else the first of the same language.
pub fn select(translations: []const Translation, locale: Locale) ?*const Translation {
    var language_only: ?*const Translation = null;
    var any_territory: ?*const Translation = null;
    for (translations) |*t| {
        const candidate: Locale = .parse(t.locale);
        if (!candidate.sameLanguage(locale)) continue;
        if (candidate.eql(locale)) return t;
        if (candidate.territory.len == 0) {
            if (language_only == null) language_only = t;
        } else if (any_territory == null) any_territory = t;
    }
    return language_only orelse any_territory;
}

/// The library's sentences in other languages, for `Translation.messages`.
pub const messages = @import("i18n_messages.zig");

const testing = std.testing;

test "Locale.parse" {
    const a: Locale = .parse("pt_BR.UTF-8");
    try testing.expectEqualStrings("pt", a.language);
    try testing.expectEqualStrings("BR", a.territory);
    const b: Locale = .parse("de@euro");
    try testing.expectEqualStrings("de", b.language);
    try testing.expectEqualStrings("", b.territory);
    const c: Locale = .parse("zh-Hans-CN");
    try testing.expectEqualStrings("Hans", c.territory);
    const d: Locale = .parse("de_DE@euro");
    try testing.expectEqualStrings("de", d.language);
    try testing.expectEqualStrings("DE", d.territory);
}

test detect {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expectEqual(null, detect(&environ));
    try environ.put("LANG", "fr_FR.UTF-8");
    try testing.expectEqualStrings("fr", detect(&environ).?.language);
    try environ.put("LC_MESSAGES", "de_AT");
    try testing.expectEqualStrings("de", detect(&environ).?.language);
    try environ.put("LC_ALL", "C.UTF-8");
    try testing.expectEqual(null, detect(&environ));
    try environ.put("LC_ALL", "");
    try testing.expectEqualStrings("AT", detect(&environ).?.territory);
}

test select {
    const all = [_]Translation{
        .{ .locale = "pt_PT" },
        .{ .locale = "pt" },
        .{ .locale = "pt_BR" },
        .{ .locale = "es_MX" },
    };
    try testing.expectEqual(&all[2], select(&all, .parse("pt_BR")).?);
    try testing.expectEqual(&all[1], select(&all, .parse("pt_AO")).?);
    try testing.expectEqual(&all[3], select(&all, .parse("es")).?);
    try testing.expectEqual(null, select(&all, .parse("de")));
}

test "text and plural forms" {
    const russian: Translation = .{ .locale = "ru", .strings = &.{
        .{ "{0} files", "{0} файл|{0} файла|{0} файлов" },
        .{ "Hello", "Привет" },
    } };
    try testing.expectEqualStrings("Привет", russian.text("Hello"));
    try testing.expectEqualStrings("Bye", russian.text("Bye"));
    try testing.expectEqualStrings("{0} файл", russian.plural(21, "{0} file", "{0} files"));
    try testing.expectEqualStrings("{0} файла", russian.plural(3, "{0} file", "{0} files"));
    try testing.expectEqualStrings("{0} файлов", russian.plural(11, "{0} file", "{0} files"));
    try testing.expectEqualStrings("{0} dir", russian.plural(1, "{0} dir", "{0} dirs"));
    try testing.expectEqualStrings("{0} dirs", russian.plural(5, "{0} dir", "{0} dirs"));
    // Fewer forms than the rule wants: the last one.
    const short: Translation = .{ .locale = "pl", .strings = &.{.{ "x", "a|b" }} };
    try testing.expectEqualStrings("b", short.plural(5, "x1", "x"));
}

test "plural rules" {
    const fr = pluralRuleFor("fr");
    try testing.expectEqual(0, fr(0));
    try testing.expectEqual(1, fr(2));
    const pl = pluralRuleFor("PL");
    try testing.expectEqual(1, pl(22));
    try testing.expectEqual(2, pl(12));
    try testing.expectEqual(2, pl(25));
    try testing.expectEqual(0, pluralRuleFor("ja")(7));
    try testing.expectEqual(1, pluralRuleFor("xx")(7));
}
