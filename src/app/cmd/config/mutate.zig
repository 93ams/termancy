//! `config set <path> <value>` and `config del <path>` - mutate a TOML file in place.
//!
//! ## Why these need a document model
//!
//! The specification's `set` says it "mutates a configuration file without destroying
//! comments or indentation". The previous implementation could not honour that: it matched
//! lines by text, re-emitted `key = value` with no indentation, and preserved only a
//! trailing `# comment`. `src/lib/cfg/toml_doc.zig` is the document model these are built on,
//! and it round-trips an untouched file byte for byte.
//!
//! ## The file is the target, not the loaded config
//!
//! `config get` and `config inspect` take a *path into a resolved config*. These take a
//! *file* to edit - a different operation with a different failure mode, which is why
//! `--file` is required rather than defaulted. Defaulting would mean a mistyped command
//! silently rewriting whichever file happened to be conventional, and the one thing a
//! mutation must not do is surprise its caller about the target.
//!
//! ## Writing is atomic in intent
//!
//! The new content is rendered fully before the file is opened for writing, so a rendering
//! error cannot truncate the original. A true atomic replace (write a temporary, then
//! rename) is **not** done here, and that is recorded rather than implied: the failure
//! window between create and write is small but real.

const std = @import("std");
const cfg = @import("cfg");

/// Flags for `config set`.
pub const SetFlags = struct {
    positionals: struct {
        /// Dotted key path, e.g. `database.pool`.
        path: []const u8 = "",
        /// The value to write.
        value: []const u8 = "",
    } = .{},

    /// The TOML file to edit. Required.
    file: []const u8 = "",
    /// Write the value as a quoted string even when it looks like a number or a boolean.
    string: bool = false,

    pub const meta = .{
        .positionals = .{ .description = "<path> <value>" },
        .file = .{ .help = "The TOML file to edit (required)" },
        .string = .{ .help = "Quote the value as a string even if it looks numeric" },
    };
};

/// Flags for `config del`.
pub const DelFlags = struct {
    positionals: struct {
        path: []const u8 = "",
    } = .{},

    file: []const u8 = "",

    pub const meta = .{
        .positionals = .{ .description = "<path>" },
        .file = .{ .help = "The TOML file to edit (required)" },
    };
};

/// Reads `file_path`, applies `set`, and writes the result back.
pub fn setFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: anytype,
    err_writer: anytype,
    path: []const u8,
    value: []const u8,
    file_path: []const u8,
    force_string: bool,
) !void {
    if (path.len == 0 or value.len == 0) {
        try err_writer.writeAll("config set: expected <path> <value>, e.g. `config set port 8080`\n");
        return error.MissingRequiredPositionalArgument;
    }
    if (file_path.len == 0) {
        try err_writer.writeAll("config set: --file is required; this command edits a file\n");
        return error.MissingRequiredFlag;
    }

    const original = readFile(allocator, io, file_path) catch |err| {
        try err_writer.print("cannot read {s}: {s}\n", .{ file_path, @errorName(err) });
        return err;
    };
    defer allocator.free(original);

    var doc = try cfg.toml_doc.parse(allocator, original);
    defer doc.deinit();

    try doc.set(path, value, shouldQuote(value, force_string));

    // Rendered before the file is touched, so a failure here leaves the original intact.
    const updated = try doc.toOwnedSlice(allocator);
    defer allocator.free(updated);

    try writeFile(io, file_path, updated);
    try writer.print("set {s} in {s}\n", .{ path, file_path });
}

/// Reads `file_path`, removes `path`, and writes the result back.
pub fn delFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: anytype,
    err_writer: anytype,
    path: []const u8,
    file_path: []const u8,
) !void {
    if (path.len == 0) {
        try err_writer.writeAll("config del: expected <path>, e.g. `config del database.pool`\n");
        return error.MissingRequiredPositionalArgument;
    }
    if (file_path.len == 0) {
        try err_writer.writeAll("config del: --file is required; this command edits a file\n");
        return error.MissingRequiredFlag;
    }

    const original = readFile(allocator, io, file_path) catch |err| {
        try err_writer.print("cannot read {s}: {s}\n", .{ file_path, @errorName(err) });
        return err;
    };
    defer allocator.free(original);

    var doc = try cfg.toml_doc.parse(allocator, original);
    defer doc.deinit();

    if (!try doc.del(path)) {
        // A miss is reported rather than treated as success: a script deleting a key that
        // was already gone should not believe it removed something.
        try err_writer.print("no such key in {s}: {s}\n", .{ file_path, path });
        return error.UnknownField;
    }

    const updated = try doc.toOwnedSlice(allocator);
    defer allocator.free(updated);

    try writeFile(io, file_path, updated);
    try writer.print("deleted {s} from {s}\n", .{ path, file_path });
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    // `Dir.readFileAlloc` rather than open/read/close: it is what the rest of this tree
    // uses, it handles the absolute-path case, and the limit is explicit.
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 24));
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

/// Whether `value` should be written as a TOML string.
///
/// Inferred rather than required, because that is what the specification asks for: a value
/// that reads as an integer, float or boolean is written bare, and anything else is
/// quoted. `--string` overrides the inference for the cases it gets wrong - a version
/// number `1.0` is a float to this rule but usually a string in practice.
pub fn shouldQuote(value: []const u8, force_string: bool) bool {
    if (force_string) return true;
    if (value.len == 0) return true;
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return false;

    // An integer: optional sign, then digits only.
    const digits = if (value[0] == '-' or value[0] == '+') value[1..] else value;
    if (digits.len > 0) {
        var all_digits = true;
        for (digits) |c| {
            if (!std.ascii.isDigit(c)) {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return false;
    }

    // A float: digits, one dot, digits. Not exhaustive - `1e5` is treated as a string,
    // which errs toward quoting and is the safe direction for a config value.
    if (std.mem.indexOfScalar(u8, value, '.')) |dot| {
        if (dot > 0 and dot + 1 < value.len) {
            var ok = true;
            for (value, 0..) |c, i| {
                if (i == dot) continue;
                if (!std.ascii.isDigit(c) and !(i == 0 and (c == '-' or c == '+'))) {
                    ok = false;
                    break;
                }
            }
            if (ok) return false;
        }
    }

    return true;
}

// -- Tests -----------------------------------------------------------------

test "type inference writes numbers and booleans bare, and text quoted" {
    // The specification's "automatically infers the value type".
    try std.testing.expect(!shouldQuote("8080", false));
    try std.testing.expect(!shouldQuote("-1", false));
    try std.testing.expect(!shouldQuote("true", false));
    try std.testing.expect(!shouldQuote("false", false));
    try std.testing.expect(!shouldQuote("3.5", false));

    try std.testing.expect(shouldQuote("hello", false));
    try std.testing.expect(shouldQuote("127.0.0.1", false)); // two dots: not a float
    try std.testing.expect(shouldQuote("1e5", false)); // errs toward quoting
    try std.testing.expect(shouldQuote("", false));

    // `--string` overrides the inference, which is what it exists for.
    try std.testing.expect(shouldQuote("8080", true));
    try std.testing.expect(shouldQuote("1.0", true));
}

test "a missing argument is refused before any file is touched" {
    const io: std.Io = undefined;
    var out_buf: [256]u8 = undefined;
    var err_buf: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err = std.Io.Writer.fixed(&err_buf);

    // No path.
    try std.testing.expectError(
        error.MissingRequiredPositionalArgument,
        setFile(std.testing.allocator, io, &out, &err, "", "1", "x.toml", false),
    );
    // No `--file`.
    try std.testing.expectError(
        error.MissingRequiredFlag,
        setFile(std.testing.allocator, io, &out, &err, "port", "1", "", false),
    );
    try std.testing.expectError(
        error.MissingRequiredFlag,
        delFile(std.testing.allocator, io, &out, &err, "port", ""),
    );
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "--file is required") != null);
}

test "the positional is declared where the framework looks for it" {
    try std.testing.expect(@hasField(SetFlags, "positionals"));
    const P = @FieldType(SetFlags, "positionals");
    try std.testing.expect(@hasField(P, "path"));
    try std.testing.expect(@hasField(P, "value"));
    try std.testing.expect(@hasField(SetFlags, "file"));
    try std.testing.expect(@hasField(SetFlags, "string"));

    try std.testing.expect(@hasField(DelFlags, "positionals"));
    try std.testing.expect(@hasField(@FieldType(DelFlags, "positionals"), "path"));
    try std.testing.expect(@hasField(DelFlags, "file"));
}

test "an inferred value is written the way the document model stores it" {
    // The link between the two halves: `shouldQuote` decides, `toml_doc.set` writes, and
    // the result must read back as the value that went in.
    var doc = try cfg.toml_doc.parse(std.testing.allocator, "");
    defer doc.deinit();

    try doc.set("port", "8080", shouldQuote("8080", false));
    try doc.set("host", "127.0.0.1", shouldQuote("127.0.0.1", false));

    try std.testing.expectEqualStrings("8080", doc.get("port").?);
    try std.testing.expectEqualStrings("127.0.0.1", doc.get("host").?);

    const text = try doc.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    // The number is bare, the address is quoted - visible in the text, which is what a
    // user reads and what a TOML parser sees.
    try std.testing.expect(std.mem.indexOf(u8, text, "port = 8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "host = \"127.0.0.1\"") != null);
}
