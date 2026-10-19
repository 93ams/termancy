//! `field` - what settings mean, shared by `cli` and `cfg`.
//!
//! A `Spec(T)` says, for each field of a struct (or variant of a tagged union), its help,
//! whether it is secret or deprecated, and the checks its value must pass; and checks that
//! span fields. Specs are keyed by type: a `Set` of them applies each one wherever its type
//! occurs, so a `Listener` spec covers `public`, `admin`, and every element of a list of
//! listeners alike. How a setting is spelled is not here: names, short flags, keys, and
//! environment variables belong to `cli.flags` and `cfg.settings`, per place.
//!
//! ```zig
//! const field = @import("field");
//!
//! const Listener = struct { host: []const u8 = "0.0.0.0", port: u16 = 8080 };
//!
//! fn notReserved(port: u16, w: *std.Io.Writer) !void {
//!     if (port == 6000) return field.fail(w, "is reserved for X11", .{});
//! }
//!
//! const listener: field.Spec(Listener) = .{ .fields = .{
//!     .host = .{ .help = "Address to bind" },
//!     .port = .{ .help = "Port to listen on", .checks = &.{ .min(1), .from(notReserved) } },
//! } };
//!
//! pub const Specs = field.Set(.{listener});
//! ```
//!
//! A check is a plain function, `fn (V, *std.Io.Writer) !void`, that writes why a value is
//! invalid and returns `error.Invalid`; the built-in ones (`min`, `max`, `minLen`,
//! `maxLen`, `oneOf`, `glob`) also describe themselves (`About`) for help, documentation,
//! schemas, and completion. Checks run on decoded values, and every failure is reported,
//! not just the first.
//!
//! The module imports only `std`.

const std = @import("std");
const check = @import("check.zig");
const spec = @import("spec.zig");
const path_ = @import("path.zig");
const name = @import("name.zig");

pub const Check = check.Check;
pub const About = check.About;
pub const Bound = check.Bound;
pub const Error = check.Error;
pub const fail = check.fail;
/// Whether `text` matches a `glob` pattern: `*` any run of bytes, `?` one byte.
pub const matches = check.matches;

pub const Field = spec.Field;
pub const Fields = spec.Fields;
pub const Spec = spec.Spec;
pub const Set = spec.Set;
pub const none = spec.none;
pub const specAt = spec.specAt;
pub const Segment = spec.Segment;
pub const validate = spec.validate;
pub const validateExcept = spec.validateExcept;
pub const checkOne = spec.checkOne;
pub const max_depth = spec.max_depth;

pub const Unwrap = path_.Unwrap;
pub const isList = path_.isList;
pub const hasParse = path_.hasParse;
pub const isGroup = path_.isGroup;
pub const isChoice = path_.isChoice;
pub const fieldNames = path_.fieldNames;
pub const fieldTypes = path_.fieldTypes;
pub const initDefaults = path_.initDefaults;
pub const initVariant = path_.initVariant;
pub const isRequired = path_.isRequired;
pub const PathType = path_.PathType;
pub const ptrAt = path_.ptrAt;
pub const getAt = path_.getAt;

pub const kebab = name.kebab;
pub const sameName = name.sameName;
pub const editDistance = name.editDistance;
pub const suggest = name.suggest;
pub const join = name.join;
pub const ordinal = name.ordinal;
pub const max_name_len = name.max_name_len;

/// Whether `S` is a `Set` of specs.
pub fn isSet(comptime S: type) bool {
    return @typeInfo(S) == .@"struct" and @hasDecl(S, "is_spec_set");
}

test {
    std.testing.refAllDecls(@This());
    _ = check;
    _ = spec;
    _ = path_;
    _ = name;
}
