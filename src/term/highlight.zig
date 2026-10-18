//! Syntax highlighting for the terminal, as chroma does it under glamour and freeze: source
//! split into tokens (keywords, types, strings, numbers, comments, ...) by a small lexer
//! that each language configures, and each token written in its theme's style.
//!
//! ```zig
//! try term.highlight.write(w, source, term.highlight.language("zig").?, .dracula);
//! ```
//!
//! The lexer knows comments (line and block), strings (with escapes, raw and multi-line
//! where the language has them), numbers, words (keywords, types, built-ins, constants, and
//! names called as functions), and punctuation; that is what makes code readable, and it
//! never fails on code it does not understand. Languages: Zig, C, C++, Rust, Go, Python,
//! JavaScript, TypeScript, Java, Kotlin, Swift, C#, Ruby, Lua, PHP, shell, PowerShell, SQL,
//! JSON, YAML, TOML, INI, HTML/XML, CSS, Dockerfile, Makefile, diff, Markdown, and VHS tapes.

const std = @import("std");
const Writer = std.Io.Writer;
const Style = @import("Style.zig");
const Color = @import("ansi.zig").Color;

/// What a piece of source is.
pub const Kind = enum {
    text,
    keyword,
    type,
    builtin,
    constant,
    function,
    string,
    escape,
    number,
    comment,
    operator,
    punctuation,
    /// A tag or attribute name in markup, a key in data.
    tag,
    attribute,
    /// Diff lines.
    inserted,
    deleted,
    heading,
};

/// A language's lexical rules.
pub const Language = struct {
    name: []const u8,
    /// Names and file extensions that pick it, lower case.
    aliases: []const []const u8,
    keywords: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    builtins: []const []const u8 = &.{},
    constants: []const []const u8 = &.{},
    line_comments: []const []const u8 = &.{},
    block_comment: ?[2][]const u8 = null,
    /// A marker that makes the rest of its line a string (Zig's `\\` lines).
    line_string: ?[]const u8 = null,
    /// Characters that open (and close) a string.
    quotes: []const u8 = "\"'",
    /// A word followed by `(` is a function.
    calls: bool = true,
    /// A word starting with this is a built-in (`@` in Zig, `$` for shell variables).
    builtin_prefix: ?u8 = null,
    /// Words compare without case (SQL).
    ignore_case: bool = false,
    /// A backslash is a backslash inside single quotes (shell, YAML, TOML).
    literal_single_quotes: bool = false,
    /// A line-oriented format with its own rules.
    special: Special = .none,

    /// Formats with rules of their own.
    pub const Special = enum { none, diff, markup, data_keys, ini, markdown };
};

/// Writes `source` highlighted for `language` in `theme`'s styles.
pub fn write(
    w: *Writer,
    source: []const u8,
    lang: *const Language,
    theme: Theme,
) Writer.Error!void {
    var lexer: Lexer = .{ .source = source, .language = lang };
    while (lexer.next()) |token| {
        const style = theme.styleOf(token.kind);
        try style.paint(w, token.text);
    }
}

/// `write` for the language named `name` (or with that extension), or as plain text when
/// no language has that name.
pub fn writeNamed(
    w: *Writer,
    source: []const u8,
    name: []const u8,
    theme: Theme,
) Writer.Error!void {
    if (language(name)) |lang| return write(w, source, lang, theme);
    try theme.styleOf(.text).paint(w, source);
}

/// One token.
pub const Token = struct {
    kind: Kind,
    text: []const u8,
};

/// Splits source into tokens.
pub const Lexer = struct {
    source: []const u8,
    language: *const Language,
    index: usize = 0,
    /// The start of the current line, for the line-oriented formats.
    at_line_start: bool = true,
    /// Inside a block comment that spans lines.
    in_block: bool = false,

    /// The next token; null at the end.
    pub fn next(lx: *Lexer) ?Token {
        if (lx.index >= lx.source.len) return null;
        const lang = lx.language;
        switch (lang.special) {
            .diff => return lx.diffLine(),
            .markdown => if (lx.at_line_start) if (lx.markdownLine()) |t| return t,
            .ini => if (lx.at_line_start) if (lx.iniSection()) |t| return t,
            else => {},
        }
        const rest = lx.source[lx.index..];
        const c = rest[0];
        if (c == '\n') {
            lx.at_line_start = true;
            return lx.take(.text, 1);
        }
        const was_line_start = lx.at_line_start;
        if (c != ' ' and c != '\t') lx.at_line_start = false;
        if (c == ' ' or c == '\t' or c == '\r') {
            var n: usize = 0;
            while (n < rest.len and (rest[n] == ' ' or rest[n] == '\t' or rest[n] == '\r')) n += 1;
            return lx.take(.text, n);
        }
        // Comments.
        if (lang.block_comment) |pair| if (std.mem.startsWith(u8, rest, pair[0])) {
            const end = std.mem.indexOfPos(u8, rest, pair[0].len, pair[1]);
            return lx.take(.comment, if (end) |e| e + pair[1].len else rest.len);
        };
        for (lang.line_comments) |marker| {
            if (!std.mem.startsWith(u8, rest, marker)) continue;
            // `#` starts a comment in shells only at a word's start.
            if (marker[0] == '#' and lx.index > 0) {
                const before = lx.source[lx.index - 1];
                if (before != ' ' and before != '\t' and before != '\n' and !was_line_start) break;
            }
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            return lx.take(.comment, end);
        }
        if (lang.special == .markup) if (lx.markup()) |t| return t;
        // Strings.
        if (lang.line_string) |marker| if (std.mem.startsWith(u8, rest, marker)) {
            return lx.take(.string, std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len);
        };
        if (std.mem.indexOfScalar(u8, lang.quotes, c) != null) return lx.string(c);
        const word_follows = rest.len > 1 and isWordStart(rest[1]);
        if (lang.builtin_prefix) |prefix| if (c == prefix and word_follows) {
            var n: usize = 1;
            while (n < rest.len and isWord(rest[n])) n += 1;
            return lx.take(.builtin, n);
        };
        if (std.ascii.isDigit(c) or (c == '.' and rest.len > 1 and std.ascii.isDigit(rest[1]))) {
            return lx.take(.number, numberLen(rest));
        }
        if (isWordStart(c)) return lx.word();
        if (std.mem.indexOfScalar(u8, "{}[]();,", c) != null) return lx.take(.punctuation, 1);
        if (std.mem.indexOfScalar(u8, "+-*/%=<>!&|^~?:.@#$\\", c) != null) {
            var n: usize = 1;
            const ops = "+-*/%=<>!&|^~?:";
            while (n < rest.len and std.mem.indexOfScalar(u8, ops, rest[n]) != null) n += 1;
            return lx.take(.operator, n);
        }
        // Anything else, a UTF-8 sequence whole.
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        return lx.take(.text, @min(len, rest.len));
    }

    fn take(lx: *Lexer, kind: Kind, n: usize) Token {
        const token: Token = .{ .kind = kind, .text = lx.source[lx.index..][0..n] };
        lx.index += n;
        return token;
    }

    fn string(lx: *Lexer, quote: u8) Token {
        const rest = lx.source[lx.index..];
        // Python's and others' triple quotes span lines.
        if (rest.len >= 3 and rest[1] == quote and rest[2] == quote and quote != '`') {
            const end = std.mem.indexOfPos(u8, rest, 3, rest[0..3]);
            return lx.take(.string, if (end) |e| e + 3 else rest.len);
        }
        var n: usize = 1;
        const spans_lines = quote == '`';
        while (n < rest.len) : (n += 1) {
            const literal = quote == '\'' and lx.language.literal_single_quotes;
            if (rest[n] == '\\' and !literal) {
                n += 1;
                continue;
            }
            if (rest[n] == quote) {
                n += 1;
                break;
            }
            if (rest[n] == '\n' and !spans_lines) break;
        }
        const len = @min(n, rest.len);
        // A key in JSON and YAML: a string followed by `:`.
        if (lx.language.special == .data_keys) {
            var after = len;
            while (after < rest.len and rest[after] == ' ') after += 1;
            if (after < rest.len and rest[after] == ':') return lx.take(.tag, len);
        }
        return lx.take(.string, len);
    }

    fn word(lx: *Lexer) Token {
        const rest = lx.source[lx.index..];
        var n: usize = 0;
        while (n < rest.len and isWord(rest[n])) n += 1;
        const text = rest[0..n];
        const lang = lx.language;
        if (lang.special == .data_keys or lang.special == .ini) {
            var after = n;
            while (after < rest.len and rest[after] == ' ') after += 1;
            const sep = if (lang.special == .ini) "=" else ":";
            if (after < rest.len and std.mem.indexOfScalar(u8, sep, rest[after]) != null) {
                return lx.take(.tag, n);
            }
        }
        if (contains(lang.keywords, text, lang.ignore_case)) return lx.take(.keyword, n);
        if (contains(lang.constants, text, lang.ignore_case)) return lx.take(.constant, n);
        if (contains(lang.types, text, lang.ignore_case)) return lx.take(.type, n);
        if (contains(lang.builtins, text, lang.ignore_case)) return lx.take(.builtin, n);
        if (lang.calls and n < rest.len and rest[n] == '(') return lx.take(.function, n);
        // A capitalized word is usually a type.
        if (lang.types.len > 0 and std.ascii.isUpper(text[0]) and n > 1 and
            !allUpper(text)) return lx.take(.type, n);
        return lx.take(.text, n);
    }

    fn diffLine(lx: *Lexer) Token {
        const rest = lx.source[lx.index..];
        const end = if (std.mem.indexOfScalar(u8, rest, '\n')) |e| e + 1 else rest.len;
        const line = rest[0..end];
        const header = std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---");
        const kind: Kind = if (header)
            .heading
        else if (line[0] == '+')
            .inserted
        else if (line[0] == '-')
            .deleted
        else if (std.mem.startsWith(u8, line, "@@"))
            .keyword
        else
            .text;
        return lx.take(kind, end);
    }

    fn markdownLine(lx: *Lexer) ?Token {
        const rest = lx.source[lx.index..];
        if (rest.len > 0 and rest[0] == '#') {
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            return lx.take(.heading, end);
        }
        return null;
    }

    fn iniSection(lx: *Lexer) ?Token {
        const rest = lx.source[lx.index..];
        if (rest.len > 0 and rest[0] == '[') {
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            lx.at_line_start = false;
            return lx.take(.heading, end);
        }
        return null;
    }

    /// Tags and their attributes, in HTML and XML.
    fn markup(lx: *Lexer) ?Token {
        const rest = lx.source[lx.index..];
        if (rest[0] == '<') {
            var n: usize = 1;
            if (n < rest.len and (rest[n] == '/' or rest[n] == '!' or rest[n] == '?')) n += 1;
            while (n < rest.len and (isWord(rest[n]) or rest[n] == ':' or rest[n] == '-')) n += 1;
            return lx.take(.tag, n);
        }
        if (rest[0] == '>' or (rest[0] == '/' and rest.len > 1 and rest[1] == '>')) {
            return lx.take(.tag, if (rest[0] == '/') 2 else 1);
        }
        if (isWordStart(rest[0])) {
            var n: usize = 0;
            while (n < rest.len and (isWord(rest[n]) or rest[n] == '-' or rest[n] == ':')) n += 1;
            if (n < rest.len and rest[n] == '=') return lx.take(.attribute, n);
        }
        if (rest[0] == '&') {
            const end = std.mem.indexOfScalar(u8, rest[0..@min(rest.len, 12)], ';');
            if (end) |e| return lx.take(.escape, e + 1);
        }
        return null;
    }
};

fn isWordStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn allUpper(text: []const u8) bool {
    for (text) |c| if (std.ascii.isLower(c)) return false;
    return true;
}

fn numberLen(rest: []const u8) usize {
    var n: usize = 0;
    // 0x.., 0b.., 0o.., digits with _, a fraction, an exponent, and a type suffix.
    while (n < rest.len) : (n += 1) {
        const c = rest[n];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') {
            // A `..` range is not part of a number.
            if (c == '.' and n + 1 < rest.len and rest[n + 1] == '.') break;
            continue;
        }
        const after_exponent = n > 0 and (rest[n - 1] == 'e' or rest[n - 1] == 'E');
        if ((c == '+' or c == '-') and after_exponent) continue;
        break;
    }
    return @max(n, 1);
}

fn contains(words: []const []const u8, text: []const u8, ignore_case: bool) bool {
    for (words) |candidate| {
        if (ignore_case) {
            if (std.ascii.eqlIgnoreCase(candidate, text)) return true;
        } else if (std.mem.eql(u8, candidate, text)) return true;
    }
    return false;
}

/// The language with this name or file extension (`zig`, `.py`, `Dockerfile`), ignoring
/// case, or null.
pub fn language(name: []const u8) ?*const Language {
    var lower: [32]u8 = undefined;
    if (name.len > lower.len) return null;
    const trimmed = std.mem.trimStart(u8, name, ".");
    const key = std.ascii.lowerString(&lower, trimmed);
    for (&languages) |*lang| {
        if (std.mem.eql(u8, lang.name, key)) return lang;
        for (lang.aliases) |alias| if (std.mem.eql(u8, alias, key)) return lang;
    }
    return null;
}

/// The language of a file, from its name: its extension, or the whole name (`Makefile`).
pub fn languageOfPath(path: []const u8) ?*const Language {
    const base = std.fs.path.basename(path);
    if (language(base)) |lang| return lang;
    const ext = std.fs.path.extension(base);
    if (ext.len > 1) return language(ext[1..]);
    return null;
}

const c_like_types = [_][]const u8{
    "int",      "char",   "float",   "double",  "void",    "long",     "short",
    "unsigned", "signed", "bool",    "size_t",  "uint8_t", "uint16_t", "uint32_t",
    "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "string",   "auto",
};

/// Every language this module knows.
pub const languages = [_]Language{
    .{
        .name = "zig",
        .aliases = &.{"zon"},
        .line_string = "\\\\",
        .keywords = &.{
            "addrspace",   "align",   "allowzero", "and",         "anyframe", "anytype",
            "asm",         "break",   "callconv",  "catch",       "comptime", "const",
            "continue",    "defer",   "else",      "enum",        "errdefer", "error",
            "export",      "extern",  "fn",        "for",         "if",       "inline",
            "linksection", "noalias", "noinline",  "nosuspend",   "opaque",   "or",
            "orelse",      "packed",  "pub",       "resume",      "return",   "struct",
            "suspend",     "switch",  "test",      "threadlocal", "try",      "union",
            "unreachable", "var",     "volatile",  "while",
        },
        .types = &.{
            "u8",             "u16",      "u32",    "u64",      "u128",      "usize",
            "i8",             "i16",      "i32",    "i64",      "i128",      "isize",
            "f16",            "f32",      "f64",    "f80",      "f128",      "bool",
            "void",           "noreturn", "type",   "anyerror", "anyopaque", "comptime_int",
            "comptime_float", "c_int",    "c_uint", "c_long",   "c_char",
        },
        .constants = &.{ "true", "false", "null", "undefined" },
        .line_comments = &.{"//"},
        .quotes = "\"'",
        .builtin_prefix = '@',
    },
    .{
        .name = "c",
        .aliases = &.{"h"},
        .keywords = &.{
            "if",      "else",     "for",      "while",   "do",     "switch",   "case",
            "default", "break",    "continue", "return",  "goto",   "struct",   "union",
            "enum",    "typedef",  "static",   "extern",  "const",  "volatile", "inline",
            "sizeof",  "register", "#include", "#define", "#ifdef", "#ifndef",  "#endif",
            "#if",     "#else",
        },
        .types = &c_like_types,
        .constants = &.{ "NULL", "true", "false" },
        .line_comments = &.{"//"},
        .block_comment = .{ "/*", "*/" },
    },
    .{
        .name = "cpp",
        .aliases = &.{ "c++", "cc", "cxx", "hpp", "hh" },
        .keywords = &.{
            "if",      "else",      "for",      "while",    "do",        "switch",   "case",
            "default", "break",     "continue", "return",   "struct",    "class",    "public",
            "private", "protected", "virtual",  "override", "template",  "typename", "namespace",
            "using",   "new",       "delete",   "const",    "constexpr", "static",   "inline",
            "auto",    "try",       "catch",    "throw",    "enum",      "operator", "this",
        },
        .types = &c_like_types,
        .constants = &.{ "nullptr", "true", "false", "NULL" },
        .line_comments = &.{"//"},
        .block_comment = .{ "/*", "*/" },
    },
    .{
        .name = "rust",
        .aliases = &.{"rs"},
        .keywords = &.{
            "as",     "async", "await",  "break",  "const",  "continue", "crate", "dyn",
            "else",   "enum",  "extern", "fn",     "for",    "if",       "impl",  "in",
            "let",    "loop",  "match",  "mod",    "move",   "mut",      "pub",   "ref",
            "return", "self",  "Self",   "static", "struct", "super",    "trait", "type",
            "unsafe", "use",   "where",  "while",
        },
        .types = &.{
            "i8",     "i16",   "i32", "i64", "i128", "isize", "u8",  "u16",    "u32", "u64",
            "u128",   "usize", "f32", "f64", "bool", "char",  "str", "String", "Vec", "Option",
            "Result",
        },
        .constants = &.{ "true", "false", "None", "Some", "Ok", "Err" },
        .line_comments = &.{"//"},
        .block_comment = .{ "/*", "*/" },
        .quotes = "\"",
    },
    .{
        .name = "go",
        .aliases = &.{"golang"},
        .keywords = &.{
            "break",  "case",        "chan", "const",   "continue", "default", "defer",
            "else",   "fallthrough", "for",  "func",    "go",       "goto",    "if",
            "import", "interface",   "map",  "package", "range",    "return",  "select",
            "struct", "switch",      "type", "var",
        },
        .types = &.{
            "bool", "byte",  "complex64", "complex128", "error",  "float32", "float64",
            "int",  "int8",  "int16",     "int32",      "int64",  "rune",    "string",
            "uint", "uint8", "uint16",    "uint32",     "uint64", "uintptr", "any",
        },
        .builtins = &.{
            "append",  "cap",     "close", "copy", "delete", "len", "make", "new", "panic", "print",
            "println", "recover",
        },
        .constants = &.{ "true", "false", "nil", "iota" },
        .line_comments = &.{"//"},
        .block_comment = .{ "/*", "*/" },
        .quotes = "\"'`",
    },
    .{
        .name = "python",
        .aliases = &.{ "py", "python3" },
        .keywords = &.{
            "and",    "as",   "assert", "async",  "await",  "break",   "class",    "continue",
            "def",    "del",  "elif",   "else",   "except", "finally", "for",      "from",
            "global", "if",   "import", "in",     "is",     "lambda",  "nonlocal", "not",
            "or",     "pass", "raise",  "return", "try",    "while",   "with",     "yield",
        },
        .types = &.{
            "int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object",
        },
        .builtins = &.{
            "print", "len",    "range", "open", "isinstance", "super", "self", "enumerate", "zip",
            "map",   "filter",
        },
        .constants = &.{ "True", "False", "None" },
        .line_comments = &.{"#"},
    },
    .{
        .name = "javascript",
        .aliases = &.{ "js", "jsx", "mjs", "cjs", "node" },
        .keywords = &.{
            "async",    "await",      "break",   "case",   "catch",    "class",  "const",
            "continue", "debugger",   "default", "delete", "do",       "else",   "export",
            "extends",  "finally",    "for",     "from",   "function", "if",     "import",
            "in",       "instanceof", "let",     "new",    "of",       "return", "static",
            "super",    "switch",     "this",    "throw",  "try",      "typeof", "var",
            "void",     "while",      "with",    "yield",
        },
        .builtins = &.{
            "console", "window", "document", "Math", "JSON", "Promise", "Array", "Object",
        },
        .constants = &.{ "true", "false", "null", "undefined", "NaN", "Infinity" },
        .line_comments = &.{"//"},
        .block_comment = .{ "/*", "*/" },
        .quotes = "\"'`",
    },
    .{
        .name = "typescript",
        .aliases = &.{ "ts", "tsx" },
        .keywords = &.{
            "abstract", "as",         "async",    "await",     "break",     "case",     "catch",
            "class",    "const",      "continue", "declare",   "default",   "do",       "else",
            "enum",     "export",     "extends",  "finally",   "for",       "from",     "function",
            "if",       "implements", "import",   "in",        "interface", "let",      "namespace",
            "new",      "of",         "private",  "protected", "public",    "readonly", "return",
            "static",   "super",      "switch",   "this",      "throw",     "try",      "type",
            "typeof",   "var",        "while",    "yield",
        },
        .types = &.{ "string", "number", "boolean", "any", "unknown", "never", "void", "object" },
        .constants = &.{ "true", "false", "null", "undefined" },
        .line_comments = &.{"//"},
        .block_comment = .{ "/*", "*/" },
        .quotes = "\"'`",
    },
    .{
        .name = "java",
        .aliases = &.{},
        .keywords = &.{
            "abstract",  "break",  "case",    "catch",      "class",        "continue",
            "default",   "do",     "else",    "enum",       "extends",      "final",
            "finally",   "for",    "if",      "implements", "import",       "instanceof",
            "interface", "new",    "package", "private",    "protected",    "public",
            "return",    "static", "super",   "switch",     "synchronized", "this",
            "throw",     "throws", "try",     "void",       "while",        "var",
            "record",
        },
        .types = &.{
            "int", "long", "short", "byte", "char", "float", "double", "boolean", "String",
        },
        .constants = &.{ "true", "false", "null" },
        .line_comments = &.{"//"},
        .block_comment = .{ "/*", "*/" },
    },
    .{
        .name = "kotlin",
        .aliases = &.{ "kt", "kts" },
        .keywords = &.{
            "as",     "break", "class",     "continue",  "do",     "else",    "for",    "fun",
            "if",     "in",    "interface", "is",        "object", "package", "return", "super",
            "this",   "throw", "try",       "typealias", "val",    "var",     "when",   "while",
            "import", "data",  "sealed",
        },
        .types = &.{ "Int", "Long", "String", "Boolean", "Double", "Float", "Any", "Unit" },
        .constants = &.{ "true", "false", "null" },
        .line_comments = &.{"//"},
        .block_comment = .{ "/*", "*/" },
    },
    .{
        .name = "swift",
        .aliases = &.{},
        .keywords = &.{
            "class",    "deinit", "enum",      "extension", "func",  "import", "init",  "let",
            "protocol", "struct", "subscript", "typealias", "var",   "break",  "case",  "continue",
            "default",  "defer",  "do",        "else",      "for",   "guard",  "if",    "in",
            "repeat",   "return", "switch",    "where",     "while", "try",    "throw", "throws",
            "self",     "public", "private",   "static",
        },
        .types = &.{ "Int", "String", "Bool", "Double", "Float", "Array", "Dictionary" },
        .constants = &.{ "true", "false", "nil" },
        .line_comments = &.{"//"},
        .block_comment = .{ "/*", "*/" },
        .quotes = "\"",
    },
    .{
        .name = "csharp",
        .aliases = &.{ "cs", "c#" },
        .keywords = &.{
            "abstract",  "as",        "async",   "await",     "base",    "break",  "case",
            "catch",     "class",     "const",   "continue",  "default", "do",     "else",
            "enum",      "event",     "finally", "for",       "foreach", "if",     "in",
            "interface", "internal",  "is",      "namespace", "new",     "out",    "override",
            "private",   "protected", "public",  "readonly",  "ref",     "return", "sealed",
            "static",    "struct",    "switch",  "this",      "throw",   "try",    "using",
            "var",       "virtual",   "void",    "while",
        },
        .types = &.{
            "int", "long", "string", "bool", "double", "float", "char", "object", "decimal",
        },
        .constants = &.{ "true", "false", "null" },
        .line_comments = &.{"//"},
        .block_comment = .{ "/*", "*/" },
    },
    .{
        .name = "ruby",
        .aliases = &.{"rb"},
        .keywords = &.{
            "alias",  "and",   "begin", "break",  "case",  "class",   "def",  "defined?", "do",
            "else",   "elsif", "end",   "ensure", "for",   "if",      "in",   "module",   "next",
            "not",    "or",    "redo",  "rescue", "retry", "return",  "self", "super",    "then",
            "unless", "until", "when",  "while",  "yield", "require",
        },
        .constants = &.{ "true", "false", "nil" },
        .line_comments = &.{"#"},
        .calls = false,
    },
    .{
        .name = "lua",
        .aliases = &.{},
        .keywords = &.{
            "and", "break", "do",  "else", "elseif", "end",    "for",  "function", "goto",  "if",
            "in",  "local", "not", "or",   "repeat", "return", "then", "until",    "while",
        },
        .constants = &.{ "true", "false", "nil" },
        .line_comments = &.{"--"},
    },
    .{
        .name = "php",
        .aliases = &.{},
        .keywords = &.{
            "abstract",  "as",      "break",   "case",      "catch",  "class",      "const",
            "continue",  "default", "do",      "echo",      "else",   "elseif",     "extends",
            "final",     "for",     "foreach", "function",  "if",     "implements", "interface",
            "namespace", "new",     "private", "protected", "public", "return",     "static",
            "switch",    "throw",   "trait",   "try",       "use",    "while",
        },
        .constants = &.{ "true", "false", "null" },
        .line_comments = &.{ "//", "#" },
        .block_comment = .{ "/*", "*/" },
        .builtin_prefix = '$',
    },
    .{
        .name = "shell",
        .aliases = &.{ "sh", "bash", "zsh", "fish", "console", "shellsession", "ksh" },
        .keywords = &.{
            "if",   "then",  "else", "elif", "fi",       "for",    "while", "until",  "do",
            "done", "case",  "esac", "in",   "function", "return", "local", "export", "readonly",
            "set",  "unset",
        },
        .builtins = &.{
            "echo",  "printf", "cd",   "pwd",   "exit", "source", "eval", "exec", "test", "read",
            "shift", "trap",   "true", "false",
        },
        .line_comments = &.{"#"},
        .builtin_prefix = '$',
        .literal_single_quotes = true,
        .calls = false,
    },
    .{
        .name = "powershell",
        .aliases = &.{ "ps1", "pwsh", "ps" },
        .keywords = &.{
            "if",     "else",  "elseif", "foreach", "for", "while", "do",    "switch",  "function",
            "return", "param", "begin",  "process", "end", "try",   "catch", "finally", "throw",
        },
        .line_comments = &.{"#"},
        .block_comment = .{ "<#", "#>" },
        .builtin_prefix = '$',
        .literal_single_quotes = true,
        .ignore_case = true,
    },
    .{
        .name = "sql",
        .aliases = &.{ "postgres", "postgresql", "mysql", "sqlite" },
        .keywords = &.{
            "select",     "from",    "where",    "and",    "or",       "not",    "insert",
            "into",       "values",  "update",   "set",    "delete",   "create", "table",
            "drop",       "alter",   "index",    "join",   "left",     "right",  "inner",
            "outer",      "on",      "group",    "by",     "order",    "having", "limit",
            "offset",     "as",      "distinct", "union",  "primary",  "key",    "foreign",
            "references", "default", "begin",    "commit", "rollback", "case",   "when",
            "then",       "else",    "end",
        },
        .types = &.{
            "integer", "int", "text", "varchar", "boolean", "real", "blob", "timestamp", "serial",
        },
        .constants = &.{ "null", "true", "false" },
        .line_comments = &.{"--"},
        .block_comment = .{ "/*", "*/" },
        .quotes = "'\"",
        .ignore_case = true,
    },
    .{
        .name = "json",
        .aliases = &.{ "jsonc", "json5", "geojson" },
        .constants = &.{ "true", "false", "null" },
        .quotes = "\"",
        .calls = false,
        .special = .data_keys,
    },
    .{
        .name = "yaml",
        .aliases = &.{"yml"},
        .constants = &.{ "true", "false", "null", "yes", "no", "on", "off", "~" },
        .line_comments = &.{"#"},
        .quotes = "\"'",
        .calls = false,
        .literal_single_quotes = true,
        .special = .data_keys,
    },
    .{
        .name = "toml",
        .aliases = &.{},
        .constants = &.{ "true", "false" },
        .line_comments = &.{"#"},
        .quotes = "\"'",
        .calls = false,
        .literal_single_quotes = true,
        .special = .ini,
    },
    .{
        .name = "ini",
        .aliases = &.{ "cfg", "conf", "properties", "editorconfig", "gitconfig", "env", "dotenv" },
        .constants = &.{ "true", "false", "yes", "no", "on", "off" },
        .line_comments = &.{ "#", ";" },
        .quotes = "\"'",
        .calls = false,
        .literal_single_quotes = true,
        .special = .ini,
    },
    .{
        .name = "html",
        .aliases = &.{ "htm", "xml", "svg", "xhtml", "vue", "plist" },
        .block_comment = .{ "<!--", "-->" },
        .quotes = "\"'",
        .calls = false,
        .special = .markup,
    },
    .{
        .name = "css",
        .aliases = &.{ "scss", "less" },
        .keywords = &.{ "@media", "@import", "@keyframes", "!important" },
        .block_comment = .{ "/*", "*/" },
        .quotes = "\"'",
        .calls = true,
        .special = .data_keys,
    },
    .{
        .name = "dockerfile",
        .aliases = &.{ "docker", "containerfile" },
        .keywords = &.{
            "FROM",       "RUN",         "CMD",    "LABEL", "EXPOSE",  "ENV", "ADD",
            "COPY",       "ENTRYPOINT",  "VOLUME", "USER",  "WORKDIR", "ARG", "ONBUILD",
            "STOPSIGNAL", "HEALTHCHECK", "SHELL",  "AS",
        },
        .line_comments = &.{"#"},
        .builtin_prefix = '$',
        .ignore_case = true,
        .calls = false,
    },
    .{
        .name = "makefile",
        .aliases = &.{ "make", "mk", "gnumakefile" },
        .keywords = &.{
            "ifeq",   "ifneq",  "ifdef", "ifndef", "else", "endif", "include", "define", "endef",
            ".PHONY", "export",
        },
        .line_comments = &.{"#"},
        .builtin_prefix = '$',
        .calls = false,
    },
    .{
        .name = "diff",
        .aliases = &.{ "patch", "udiff" },
        .special = .diff,
    },
    .{
        .name = "markdown",
        .aliases = &.{ "md", "mkd" },
        .quotes = "`",
        .calls = false,
        .special = .markdown,
    },
    .{
        .name = "tape",
        .aliases = &.{"vhs"},
        .keywords = &.{
            "Output",  "Set",      "Type",  "Sleep",  "Hide",  "Show",  "Screenshot", "Wait",
            "Require", "Source",   "Env",   "Copy",   "Paste", "Enter", "Backspace",  "Delete",
            "Insert",  "Tab",      "Space", "Escape", "Up",    "Down",  "Left",       "Right",
            "PageUp",  "PageDown", "Home",  "End",    "Ctrl",  "Alt",   "Shift",
        },
        .line_comments = &.{"#"},
        .quotes = "\"'`",
        .calls = false,
    },
};

/// The styles for each kind of token.
pub const Theme = struct {
    text: Style = .{},
    keyword: Style = .{},
    type: Style = .{},
    builtin: Style = .{},
    constant: Style = .{},
    function: Style = .{},
    string: Style = .{},
    escape: Style = .{},
    number: Style = .{},
    comment: Style = .{},
    operator: Style = .{},
    punctuation: Style = .{},
    tag: Style = .{},
    attribute: Style = .{},
    inserted: Style = .{},
    deleted: Style = .{},
    heading: Style = .{},
    /// The background a code block is drawn on, for those who draw one (freeze, markdown).
    background: Color = .default,

    /// The style for tokens of `kind`.
    pub fn styleOf(theme: Theme, kind: Kind) Style {
        return switch (kind) {
            inline else => |tag| @field(theme, @tagName(tag)),
        };
    }

    /// Charm's colors, the default.
    pub const charm: Theme = .{
        .text = .{ .fg = .hex(0xc4c4c4) },
        .keyword = .{ .fg = .hex(0x00aaff) },
        .type = .{ .fg = .hex(0x6e6ed8) },
        .builtin = .{ .fg = .hex(0xfe5f86) },
        .constant = .{ .fg = .hex(0xff5fd2) },
        .function = .{ .fg = .hex(0x00d787) },
        .string = .{ .fg = .hex(0xc69669) },
        .escape = .{ .fg = .hex(0xafffd7) },
        .number = .{ .fg = .hex(0x6eefc0) },
        .comment = .{ .fg = .hex(0x676767), .italic = true },
        .operator = .{ .fg = .hex(0xef8080) },
        .punctuation = .{ .fg = .hex(0xe8e8a8) },
        .tag = .{ .fg = .hex(0xb083ea) },
        .attribute = .{ .fg = .hex(0x7a7ae6) },
        .inserted = .{ .fg = .hex(0x00d787) },
        .deleted = .{ .fg = .hex(0xfd5b5b) },
        .heading = .{ .fg = .hex(0x00aaff), .bold = true },
        .background = .hex(0x171717),
    };
    /// Dracula.
    pub const dracula: Theme = .{
        .text = .{ .fg = .hex(0xf8f8f2) },
        .keyword = .{ .fg = .hex(0xff79c6) },
        .type = .{ .fg = .hex(0x8be9fd), .italic = true },
        .builtin = .{ .fg = .hex(0x8be9fd) },
        .constant = .{ .fg = .hex(0xbd93f9) },
        .function = .{ .fg = .hex(0x50fa7b) },
        .string = .{ .fg = .hex(0xf1fa8c) },
        .escape = .{ .fg = .hex(0xff79c6) },
        .number = .{ .fg = .hex(0xbd93f9) },
        .comment = .{ .fg = .hex(0x6272a4) },
        .operator = .{ .fg = .hex(0xff79c6) },
        .punctuation = .{ .fg = .hex(0xf8f8f2) },
        .tag = .{ .fg = .hex(0xff79c6) },
        .attribute = .{ .fg = .hex(0x50fa7b) },
        .inserted = .{ .fg = .hex(0x50fa7b) },
        .deleted = .{ .fg = .hex(0xff5555) },
        .heading = .{ .fg = .hex(0xbd93f9), .bold = true },
        .background = .hex(0x282a36),
    };
    /// Monokai.
    pub const monokai: Theme = .{
        .text = .{ .fg = .hex(0xf8f8f2) },
        .keyword = .{ .fg = .hex(0xf92672) },
        .type = .{ .fg = .hex(0x66d9ef), .italic = true },
        .builtin = .{ .fg = .hex(0x66d9ef) },
        .constant = .{ .fg = .hex(0xae81ff) },
        .function = .{ .fg = .hex(0xa6e22e) },
        .string = .{ .fg = .hex(0xe6db74) },
        .escape = .{ .fg = .hex(0xae81ff) },
        .number = .{ .fg = .hex(0xae81ff) },
        .comment = .{ .fg = .hex(0x75715e) },
        .operator = .{ .fg = .hex(0xf92672) },
        .punctuation = .{ .fg = .hex(0xf8f8f2) },
        .tag = .{ .fg = .hex(0xf92672) },
        .attribute = .{ .fg = .hex(0xa6e22e) },
        .inserted = .{ .fg = .hex(0xa6e22e) },
        .deleted = .{ .fg = .hex(0xf92672) },
        .heading = .{ .fg = .hex(0x66d9ef), .bold = true },
        .background = .hex(0x272822),
    };
    /// Tokyo Night.
    pub const tokyo_night: Theme = .{
        .text = .{ .fg = .hex(0xa9b1d6) },
        .keyword = .{ .fg = .hex(0xbb9af7) },
        .type = .{ .fg = .hex(0x2ac3de) },
        .builtin = .{ .fg = .hex(0x7dcfff) },
        .constant = .{ .fg = .hex(0xff9e64) },
        .function = .{ .fg = .hex(0x7aa2f7) },
        .string = .{ .fg = .hex(0x9ece6a) },
        .escape = .{ .fg = .hex(0x89ddff) },
        .number = .{ .fg = .hex(0xff9e64) },
        .comment = .{ .fg = .hex(0x565f89), .italic = true },
        .operator = .{ .fg = .hex(0x89ddff) },
        .punctuation = .{ .fg = .hex(0xa9b1d6) },
        .tag = .{ .fg = .hex(0xf7768e) },
        .attribute = .{ .fg = .hex(0xbb9af7) },
        .inserted = .{ .fg = .hex(0x9ece6a) },
        .deleted = .{ .fg = .hex(0xf7768e) },
        .heading = .{ .fg = .hex(0x7aa2f7), .bold = true },
        .background = .hex(0x1a1b26),
    };
    /// For light backgrounds.
    pub const github: Theme = .{
        .text = .{ .fg = .hex(0x24292e) },
        .keyword = .{ .fg = .hex(0xd73a49) },
        .type = .{ .fg = .hex(0x6f42c1) },
        .builtin = .{ .fg = .hex(0x005cc5) },
        .constant = .{ .fg = .hex(0x005cc5) },
        .function = .{ .fg = .hex(0x6f42c1) },
        .string = .{ .fg = .hex(0x032f62) },
        .escape = .{ .fg = .hex(0x22863a) },
        .number = .{ .fg = .hex(0x005cc5) },
        .comment = .{ .fg = .hex(0x6a737d), .italic = true },
        .operator = .{ .fg = .hex(0xd73a49) },
        .punctuation = .{ .fg = .hex(0x24292e) },
        .tag = .{ .fg = .hex(0x22863a) },
        .attribute = .{ .fg = .hex(0x6f42c1) },
        .inserted = .{ .fg = .hex(0x22863a) },
        .deleted = .{ .fg = .hex(0xb31d28) },
        .heading = .{ .fg = .hex(0x005cc5), .bold = true },
        .background = .hex(0xf6f8fa),
    };
    /// The terminal's 16 colors.
    pub const ansi: Theme = .{
        .keyword = .{ .fg = .magenta },
        .type = .{ .fg = .cyan },
        .builtin = .{ .fg = .blue },
        .constant = .{ .fg = .yellow },
        .function = .{ .fg = .green },
        .string = .{ .fg = .yellow },
        .escape = .{ .fg = .cyan },
        .number = .{ .fg = .cyan },
        .comment = .{ .fg = .bright_black, .italic = true },
        .operator = .{},
        .tag = .{ .fg = .blue },
        .attribute = .{ .fg = .cyan },
        .inserted = .{ .fg = .green },
        .deleted = .{ .fg = .red },
        .heading = .{ .bold = true },
    };

    /// The theme named `name` (`charm`, `dracula`, `monokai`, `tokyo-night`, `github`,
    /// `ansi`), or null.
    pub fn named(name: []const u8) ?Theme {
        const themes = [_]struct { []const u8, Theme }{
            .{ "charm", charm },             .{ "dracula", dracula },
            .{ "monokai", monokai },         .{ "tokyo-night", tokyo_night },
            .{ "tokyo_night", tokyo_night }, .{ "github", github },
            .{ "ansi", ansi },
        };
        for (themes) |t| if (std.ascii.eqlIgnoreCase(t[0], name)) return t[1];
        return null;
    }
};

const testing = std.testing;

fn expectTokens(
    lang_name: []const u8,
    source: []const u8,
    expected: []const struct { Kind, []const u8 },
) !void {
    var lexer: Lexer = .{ .source = source, .language = language(lang_name).? };
    for (expected) |e| {
        var token = lexer.next() orelse return error.TestUnexpectedResult;
        while (token.kind == .text and std.mem.trim(u8, token.text, " \n").len == 0) {
            token = lexer.next() orelse return error.TestUnexpectedResult;
        }
        if (token.kind != e[0] or !std.mem.eql(u8, token.text, e[1])) {
            std.debug.print(
                "expected {t} \"{s}\", got {t} \"{s}\"\n",
                .{ e[0], e[1], token.kind, token.text },
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "zig" {
    try expectTokens("zig", "const x: u8 = @intCast(0x1F); // hi\nfoo(\"a\\\"b\");", &.{
        .{ .keyword, "const" }, .{ .text, "x" },            .{ .operator, ":" },
        .{ .type, "u8" },       .{ .operator, "=" },        .{ .builtin, "@intCast" },
        .{ .punctuation, "(" }, .{ .number, "0x1F" },       .{ .punctuation, ")" },
        .{ .punctuation, ";" }, .{ .comment, "// hi" },     .{ .function, "foo" },
        .{ .punctuation, "(" }, .{ .string, "\"a\\\"b\"" },
    });
}

test "python, shell, json, yaml, diff" {
    try expectTokens("py", "def f(): return None  # x", &.{
        .{ .keyword, "def" },   .{ .function, "f" },  .{ .punctuation, "(" },
        .{ .punctuation, ")" }, .{ .operator, ":" },  .{ .keyword, "return" },
        .{ .constant, "None" }, .{ .comment, "# x" },
    });
    try expectTokens("bash", "echo $HOME a#b # c", &.{
        .{ .builtin, "echo" }, .{ .builtin, "$HOME" }, .{ .text, "a" },
        .{ .operator, "#" },   .{ .text, "b" },        .{ .comment, "# c" },
    });
    try expectTokens("json", "{\"a\": 1, \"b\": \"c\"}", &.{
        .{ .punctuation, "{" }, .{ .tag, "\"a\"" }, .{ .operator, ":" }, .{ .number, "1" },
        .{ .punctuation, "," }, .{ .tag, "\"b\"" }, .{ .operator, ":" }, .{ .string, "\"c\"" },
    });
    try expectTokens("yaml", "name: ada\non: true", &.{
        .{ .tag, "name" }, .{ .operator, ":" }, .{ .text, "ada" },
        .{ .tag, "on" },   .{ .operator, ":" }, .{ .constant, "true" },
    });
    try expectTokens("diff", "--- a\n+new\n-old\n same", &.{
        .{ .heading, "--- a\n" }, .{ .inserted, "+new\n" }, .{ .deleted, "-old\n" },
    });
}

test "language lookup by name and path" {
    try testing.expectEqualStrings("zig", language("ZIG").?.name);
    try testing.expectEqualStrings("python", language(".py").?.name);
    try testing.expectEqualStrings("makefile", languageOfPath("src/Makefile").?.name);
    try testing.expectEqualStrings("typescript", languageOfPath("app.tsx").?.name);
    try testing.expectEqual(null, language("brainfudge"));
}

test "highlighting writes every byte, in the theme's styles" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const source = "fn main() void {\n    // ok\n}\n";
    try write(&out.writer, source, language("zig").?, .charm);
    var plain: Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    try @import("ansi.zig").strip(&plain.writer, out.written());
    try testing.expectEqualStrings(source, plain.written());
    try testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[38;2;0;170;255mfn") != null);
    // Unknown text round-trips too, even bytes that are not UTF-8.
    var lexer: Lexer = .{ .source = "\xff\xfe x", .language = language("c").? };
    var total: usize = 0;
    while (lexer.next()) |token| total += token.text.len;
    try testing.expectEqual(4, total);
}
