//! `cli.flags` and `cli.args`: a struct's fields as flags or as positionals. What each field
//! means (help, secret, deprecated, checks) comes from `field` specs, by type; how it is
//! spelled on the command line comes from the options here, per place.
//!
//! ```zig
//! const serve_flags = cli.flags(ServeFlags, Specs, .{
//!     .fields = .{
//!         .port = .{ .short = 'p', .env = "PORT" },
//!         .verbose = .{ .short = 'v', .count = true },
//!         .tags = .{ .name = "tag", .split = ',' },
//!         .public = .{ .fields = .{ .host = .{ .short = 'H' } } }, // --public-host
//!         .attempts = .{ .internal = true },                       // state, not a flag
//!     },
//!     .exclusive = &.{&.{ .json, .yaml }},
//! });
//! const serve = cli.command(.{ .name = "serve", .flags = serve_flags, .run = run });
//! ```
//!
//! A field that is a struct is a group of flags named after it (`--public-host`; `.name`
//! renames the prefix, `.name = ""` drops it, and `.separator = "."` spells it
//! `--public.host`). A group's place (`cli.GroupPlace`) does not depend on the struct it is
//! in, so one can be declared once and shared. `.env_prefix`, for the whole set or a group,
//! gives every flag under it a variable: the prefix and the flag's name in SCREAMING_SNAKE
//! (`APP_` gives `--public-host` the variable `APP_PUBLIC_HOST`), unless the flag names its
//! own `.env`. A tagged union is a choice: a flag naming
//! the variant (`--storage s3`), and each variant's fields as a group under it
//! (`--storage-s3-bucket`, which also picks `s3`). A list of structs cannot be flags and
//! must be marked `.internal`.

const std = @import("std");
const field = @import("field");
const Flag = @import("Flag.zig");
const Command = @import("Command.zig");
const Context = @import("Context.zig");
const values = @import("values.zig");
const text = @import("text.zig");

/// A completer given to `.complete`: `.complete = .from(completeRegion)`.
pub const Complete = struct {
    call: Command.Completer,

    /// `f` is `fn (*cli.Context, []const u8) ![]const cli.Candidate`.
    pub fn from(comptime f: anytype) Complete {
        return .{ .call = completer(@typeName(@TypeOf(f)), f) };
    }
};

/// Checks a completer's signature and returns a pointer to it.
pub fn completer(comptime where: []const u8, comptime function: anytype) Command.Completer {
    const F = @TypeOf(function);
    const Fn = switch (@typeInfo(F)) {
        .@"fn" => F,
        .pointer => |pointer| pointer.child,
        else => @compileError(where ++ ": .complete must be a function"),
    };
    const info = @typeInfo(Fn).@"fn";
    const ok = info.param_types.len == 2 and info.param_types[0] == *Context and
        info.param_types[1] == []const u8;
    if (!ok) {
        @compileError(where ++
            ": .complete must be fn (*cli.Context, []const u8) ![]const cli.Candidate");
    }
    return &struct {
        fn call(ctx: *Context, prefix: []const u8) anyerror![]const Command.Candidate {
            return function(ctx, prefix);
        }
    }.call;
}

// -- Options ---------------------------------------------------------------------------

/// How the fields of `T` are spelled as flags, and which go together.
pub fn FlagOptions(comptime T: type) type {
    const Name = std.meta.FieldEnum(T);
    return struct {
        fields: FlagFields(T) = .{},
        /// Read each flag from the variable named by this prefix and the flag's name in
        /// SCREAMING_SNAKE (`APP_` gives `--dry-run` `APP_DRY_RUN`), unless it names its own
        /// `.env`.
        env_prefix: ?[]const u8 = null,
        /// In each group, at most one may be given.
        exclusive: []const []const Name = &.{},
        /// In each group, all or none must be given.
        together: []const []const Name = &.{},
        /// In each group, at least one must be given.
        one_required: []const []const Name = &.{},
    };
}

/// One `FlagPlace` per field of the struct `T`, or per variant of the choice `T`.
pub fn FlagFields(comptime T: type) type {
    const names = field.fieldNames(T);
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (field.fieldTypes(T), &types, &attrs) |F, *t, *a| {
        t.* = FlagPlace(T, F);
        a.* = .{ .default_value_ptr = &@as(FlagPlace(T, F), .{}) };
    }
    return @Struct(.auto, null, names, &types, &attrs);
}

/// The options of one field of `Parent`, of type `V`.
pub fn FlagPlace(comptime Parent: type, comptime V: type) type {
    const C = field.Unwrap(V);
    if (C == void) return struct {};
    if (field.isGroup(C)) return GroupPlace(C);
    if (field.isList(C) and field.isGroup(@typeInfo(C).pointer.child)) return struct {
        /// A list of structs cannot be flags, so it must say so.
        internal: bool = false,
    };
    if (field.isChoice(C)) return struct {
        /// The flag naming the variant, and the prefix of the variants' flags.
        name: ?[]const u8 = null,
        short: ?u8 = null,
        aliases: []const []const u8 = &.{},
        env: ?[]const u8 = null,
        hidden: bool = false,
        internal: bool = false,
        prompt: ?[]const u8 = null,
        feature: ?[]const u8 = null,
        /// Each variant's group: its prefix and its fields' places.
        variants: FlagFields(C) = .{},
    };
    return struct {
        /// The long name, instead of the field's name in kebab case.
        name: ?[]const u8 = null,
        /// The one-letter spelling: `'p'` for `-p`.
        short: ?u8 = null,
        /// Other long names accepted, such as one before a rename.
        aliases: []const []const u8 = &.{},
        /// The placeholder in help, instead of one from the type.
        value_name: ?[]const u8 = null,
        /// Read when the flag is not given.
        env: ?[]const u8 = null,
        /// Accepted, but not shown in help or completion.
        hidden: bool = false,
        /// Not a flag: the field is state (a `cli.Flow`'s, say) and keeps its default.
        internal: bool = false,
        /// Asked for with this label when it is required and missing in an interactive run.
        prompt: ?[]const u8 = null,
        /// Values offered for completion, beyond an enum's names: `.from(fn)`.
        complete: ?Complete = null,
        /// The flag exists only while this feature is on (see `App.feature_enabled`).
        feature: ?[]const u8 = null,
        /// Siblings that must be given with this one.
        requires: []const std.meta.FieldEnum(Parent) = &.{},
        /// An integer field counts occurrences: `-vvv`.
        count: bool = false,
        /// A list field also splits each value on this byte.
        split: ?u8 = null,
    };
}

/// The options of a field that is a group of flags, the struct `C`. It is the same type
/// whatever struct the group is in, so a group's spelling can be declared once and shared.
pub fn GroupPlace(comptime C: type) type {
    return struct {
        /// The prefix of the group's flags (`--public-host`), instead of the field's name;
        /// `""` puts them at this level.
        name: ?[]const u8 = null,
        /// Between the prefix and each flag's own name: `"."` spells `--public.host`.
        separator: []const u8 = "-",
        /// The variables' prefix for the group's flags, instead of the enclosing prefix and
        /// the group's name (`APP_PUBLIC_`); see `FlagOptions.env_prefix`.
        env_prefix: ?[]const u8 = null,
        hidden: bool = false,
        /// Not flags: the fields keep their defaults.
        internal: bool = false,
        fields: FlagFields(C) = .{},
    };
}

/// How the fields of `T` are spelled as positionals.
pub fn ArgOptions(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    var types: [info.field_names.len]type = undefined;
    var attrs: [info.field_names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (&types, &attrs) |*t, *a| {
        t.* = ArgPlace;
        a.* = .{ .default_value_ptr = &@as(ArgPlace, .{}) };
    }
    const Fields = @Struct(.auto, null, info.field_names, &types, &attrs);
    return struct { fields: Fields = .{} };
}

pub const ArgPlace = struct {
    /// The name in usage and messages, instead of the field's name in kebab case.
    name: ?[]const u8 = null,
    complete: ?Complete = null,
    /// Asked for with this label when it is required and missing in an interactive run.
    prompt: ?[]const u8 = null,
};

// -- Sets ------------------------------------------------------------------------------

/// The flags the fields of `T` become, with what they mean from the specs in `S` (a
/// `field.Set`) and how they are spelled from `options`. Give it to a command's `.flags`
/// or `.persistent_flags`; a handler takes the plain `T`.
pub fn flags(comptime T: type, comptime S: type, comptime options: FlagOptions(T)) type {
    if (@typeInfo(T) != .@"struct") {
        @compileError("cli: flags must be a struct, found " ++ @typeName(T));
    }
    if (comptime !field.isSet(S)) {
        @compileError("cli.flags: " ++ @typeName(S) ++ " is not a field.Set");
    }
    return struct {
        pub const is_flag_set = true;
        pub const Value = T;
        pub const Specs = S;
        const built = build(T, S, options);
        /// One per field that is a flag, groups flattened.
        pub const list: []const Flag = built.flags;
        /// The groups' prefixes, for naming a group in messages: `--public-*`.
        pub const groups: []const Group = built.groups;
        pub const constraints: Command.Constraints = constraintsOf(T, options, built.flags);
    };
}

/// The positionals the fields of `T` become, in order: fields without a default (or `?`)
/// are required and come first, and the last may be a list taking the remaining words.
/// Give it to a command's `.args`; a handler takes the plain `T`.
pub fn args(comptime T: type, comptime S: type, comptime options: ArgOptions(T)) type {
    if (@typeInfo(T) != .@"struct") {
        @compileError("cli: .args must be a struct type, found " ++ @typeName(T));
    }
    if (comptime !field.isSet(S)) {
        @compileError("cli.args: " ++ @typeName(S) ++ " is not a field.Set");
    }
    return struct {
        pub const is_arg_set = true;
        pub const Value = T;
        pub const Specs = S;
        pub const command_args: Command.Args = typedArgs(T, S, options);
    };
}

/// `X` as a flag set: itself, or a plain struct with no specs or options.
pub fn FlagSet(comptime X: type) type {
    if (@typeInfo(X) != .@"struct") {
        @compileError("cli: flags must be a struct, found " ++ @typeName(X));
    }
    if (@hasDecl(X, "is_flag_set")) return X;
    return flags(X, field.none, .{});
}

/// `X` as a positional set: itself, or a plain struct with no specs or options.
pub fn ArgSet(comptime X: type) type {
    if (@typeInfo(X) != .@"struct") {
        @compileError("cli: .args must be a struct type, found " ++ @typeName(X));
    }
    if (@hasDecl(X, "is_arg_set")) return X;
    return args(X, field.none, .{});
}

/// A group of flags, for messages about the whole group.
pub const Group = struct { path: []const u8, prefix: []const u8 };

const Built = struct { flags: []const Flag, groups: []const Group };

fn build(comptime T: type, comptime S: type, comptime options: FlagOptions(T)) Built {
    comptime {
        @setEvalBranchQuota(10_000 + 20_000 * field.fieldNames(T).len);
        var out: Built = .{ .flags = &.{}, .groups = &.{} };
        const env = options.env_prefix;
        collect(T, T, S, options.fields, "", "", null, "", false, "-", env, &out);
        // `.requires` named fields; now that every flag has its name, name the flags.
        var final: [out.flags.len]Flag = out.flags[0..out.flags.len].*;
        for (&final) |*flag| {
            var names: []const []const u8 = &.{};
            for (flag.requires) |path| names = names ++ .{nameAt(out.flags, path, flag.name)};
            flag.requires = names;
        }
        const flags_ = final;
        return .{ .flags = &flags_, .groups = out.groups };
    }
}

fn nameAt(
    comptime all: []const Flag,
    comptime path: []const u8,
    comptime who: []const u8,
) []const u8 {
    for (all) |f| if (std.mem.eql(u8, f.field, path)) return f.name;
    @compileError("cli: --" ++ who ++ " requires " ++ path ++ ", which is not a flag");
}

fn join(comptime parent: []const u8, comptime name: []const u8) []const u8 {
    return if (parent.len == 0) name else parent ++ "." ++ name;
}

fn prefixed(
    comptime prefix: []const u8,
    comptime separator: []const u8,
    comptime own: []const u8,
) []const u8 {
    if (own.len == 0) return prefix;
    return if (prefix.len == 0) own else prefix ++ separator ++ own;
}

/// The variable prefix under `env` for a group spelled `own`: `APP_` and `public` give
/// `APP_PUBLIC_`; none without `env`.
fn envPrefix(comptime env: ?[]const u8, comptime own: []const u8) ?[]const u8 {
    const prefix = env orelse return null;
    return if (own.len == 0) prefix else prefix ++ screaming(own) ++ "_";
}

/// `dry-run` or `cursor.fg` as part of a variable's name: `DRY_RUN`, `CURSOR_FG`.
fn screaming(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        for (name, &out) |c, *o| o.* = if (c == '-' or c == '.') '_' else std.ascii.toUpper(c);
        const final = out;
        return &final;
    }
}

fn collect(
    comptime Root: type,
    comptime T: type,
    comptime S: type,
    comptime places: FlagFields(T),
    comptime prefix: []const u8,
    comptime path: []const u8,
    comptime choice: ?[]const u8,
    comptime variant: []const u8,
    comptime hidden: bool,
    /// Between `prefix` and each flag's own name.
    comptime separator: []const u8,
    /// The variables' prefix here; null when the flags have none but their own `.env`.
    comptime env: ?[]const u8,
    comptime out: *Built,
) void {
    const spec = S.of(T);
    const defaults = field.initDefaults(Root);
    for (field.fieldNames(T), field.fieldTypes(T)) |name, F| {
        const place = @field(places, name);
        const C = field.Unwrap(F);
        const sub = join(path, name);
        if (field.isList(C) and field.isGroup(@typeInfo(C).pointer.child)) {
            if (!place.internal) @compileError("cli: " ++ sub ++
                ": a list of structs cannot be flags; set .internal = true");
            continue;
        }
        if (@hasField(@TypeOf(place), "internal") and place.internal) continue;
        const hide = hidden or place.hidden;
        const own = place.name orelse text.kebab(name);
        const long = prefixed(prefix, separator, own);
        const field_spec = @field(spec.fields, name);
        if (field.isGroup(C)) {
            out.groups = out.groups ++ .{Group{ .path = sub, .prefix = long }};
            const genv = place.env_prefix orelse envPrefix(env, own);
            const sep = place.separator;
            collect(Root, C, S, place.fields, long, sub, choice, variant, hide, sep, genv, out);
            continue;
        }
        var flag: Flag = .{
            .name = long,
            .aliases = place.aliases,
            .field = sub,
            .owner = @typeName(Root),
            .kind = .value,
            .short = place.short,
            .help = field_spec.help,
            .env = place.env orelse if (env) |e| e ++ screaming(own) else null,
            .hidden = hide,
            .deprecated = field_spec.deprecated,
            .prompt = place.prompt,
            .secret = field_spec.secret,
            .feature = place.feature,
            .choice = choice,
            .variant = variant,
            .check = undefined,
        };
        if (field.isChoice(C)) {
            flag.value_name = values.label(C);
            flag.value_type = .@"enum";
            flag.choices = values.choices(C);
            flag.check = values.checker(C);
            flag.required = field.isRequired(Root, sub) and choice == null;
            if (field.getAt(Root, sub, &defaults)) |d| flag.write_default = defaultWriter(C, d.*);
            out.flags = out.flags ++ .{flag};
            for (field.fieldNames(C), field.fieldTypes(C)) |vn, P| {
                if (P == void) continue;
                const vplace = @field(place.variants, vn);
                if (vplace.internal) continue;
                const vown = vplace.name orelse text.kebab(vn);
                const vprefix = prefixed(long, "-", vown);
                const vpath = join(sub, vn);
                out.groups = out.groups ++ .{Group{ .path = vpath, .prefix = vprefix }};
                const vhide = hide or vplace.hidden;
                const venv = vplace.env_prefix orelse envPrefix(envPrefix(env, own), vown);
                const vsep = vplace.separator;
                const vfields = vplace.fields;
                collect(Root, P, S, vfields, vprefix, vpath, long, vn, vhide, vsep, venv, out);
            }
            continue;
        }
        const list = field.isList(C);
        const Elem = values.Element(F);
        if (place.count and @typeInfo(C) != .int) {
            @compileError("cli: --" ++ long ++ ": .count needs an integer field, found " ++
                @typeName(F));
        }
        if (place.split != null and !list) {
            @compileError("cli: --" ++ long ++ ": .split needs a list field, found " ++
                @typeName(F));
        }
        _ = values.checker(Elem); // Rejects unsupported types here.
        flag.kind = if (Elem == bool and !list) .bool else if (place.count) .count else .value;
        flag.repeatable = list or flag.kind == .count;
        flag.split = place.split;
        flag.value_type = values.valueType(Elem);
        const checks = if (list) field_spec.each else field_spec.checks;
        const one_of = oneOf(checks);
        flag.choices = if (one_of.len > 0) one_of else values.choices(Elem);
        flag.value_name = if (flag.kind == .value)
            place.value_name orelse
                (if (one_of.len > 0) field.join(one_of, "|") else values.label(Elem))
        else
            "";
        flag.about = abouts(field_spec.checks) ++ abouts(field_spec.each);
        flag.validate = validator(Elem, checks);
        flag.required = field.isRequired(Root, sub) and flag.kind == .value and !list and
            choice == null;
        flag.check = if (flag.kind == .count) values.checker(bool) else values.checker(Elem);
        if (place.complete) |c| flag.complete = c.call;
        var requires: []const []const u8 = &.{};
        for (place.requires) |r| requires = requires ++ .{join(path, @tagName(r))};
        flag.requires = requires;
        if (field.getAt(Root, sub, &defaults)) |d| {
            if (!field.isRequired(Root, sub)) flag.write_default = defaultWriter(F, d.*);
        }
        out.flags = out.flags ++ .{flag};
    }
}

fn oneOf(comptime checks: anytype) []const []const u8 {
    for (checks) |c| if (c.about) |a| if (a == .one_of) return a.one_of;
    return &.{};
}

fn abouts(comptime checks: anytype) []const field.About {
    var out: []const field.About = &.{};
    for (checks) |c| if (c.about) |a| {
        out = out ++ .{a};
    };
    return out;
}

/// `Flag.validate` for one value of `Elem` and `checks`, or null without checks.
fn validator(
    comptime Elem: type,
    comptime checks: anytype,
) ?*const fn ([]const u8, *std.Io.Writer, *?field.About) field.Error!void {
    if (checks.len == 0) return null;
    return &struct {
        fn validate(word: []const u8, w: *std.Io.Writer, about: *?field.About) field.Error!void {
            // A word of the wrong type is reported by `Flag.check`.
            const value = values.parse(Elem, word) catch return;
            inline for (checks) |c| {
                c.run(value, w) catch |err| {
                    about.* = c.about;
                    return err;
                };
            }
        }
    }.validate;
}

fn defaultWriter(
    comptime Field: type,
    comptime value: Field,
) ?*const fn (*std.Io.Writer) std.Io.Writer.Error!void {
    if (comptime !values.isInteresting(Field, value)) return null;
    if (@typeInfo(Field) == .int and value == 0) return null;
    return &struct {
        fn write(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try values.write(Field, value, writer);
        }
    }.write;
}

fn constraintsOf(
    comptime T: type,
    comptime options: FlagOptions(T),
    comptime all: []const Flag,
) Command.Constraints {
    comptime {
        var result: Command.Constraints = .{};
        for (.{ "exclusive", "together", "one_required" }) |kind| {
            var groups: []const []const []const u8 = &.{};
            for (@field(options, kind)) |group| {
                var names: []const []const u8 = &.{};
                for (group) |f| names = names ++ .{nameAt(all, @tagName(f), @tagName(f))};
                groups = groups ++ .{names};
            }
            @field(result, kind) = groups;
        }
        return result;
    }
}

// -- Positionals -----------------------------------------------------------------------

fn typedArgs(comptime T: type, comptime S: type, comptime options: ArgOptions(T)) Command.Args {
    comptime {
        const where = "cli.args(" ++ @typeName(T) ++ "): ";
        const info = @typeInfo(T).@"struct";
        const spec = S.of(T);
        var min: usize = 0;
        var max: ?usize = info.field_names.len;
        var usage: []const u8 = "";
        var optional_seen = false;
        var positionals: [info.field_names.len]Command.Positional = undefined;
        var any_complete = false;
        for (info.field_names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, i| {
            const place = @field(options.fields, name);
            const label = place.name orelse text.kebab(name);
            const optional = @typeInfo(Field) == .optional or attrs.default_value_ptr != null;
            const list = values.isList(field.Unwrap(Field));
            _ = values.checker(values.Element(Field)); // Rejects unsupported types here.
            if (list and i + 1 != info.field_names.len) {
                @compileError(where ++ "only the last positional may be a list: " ++ name);
            }
            if (!optional and optional_seen) {
                @compileError(where ++ "required positional " ++ name ++
                    " follows an optional one");
            }
            if (optional) optional_seen = true else min += 1;
            if (list) max = null;
            const piece = if (list and optional)
                "[" ++ label ++ "...]"
            else if (list)
                "<" ++ label ++ ">..."
            else if (optional)
                "[" ++ label ++ "]"
            else
                "<" ++ label ++ ">";
            usage = usage ++ (if (i > 0) " " else "") ++ piece;
            const field_spec = @field(spec.fields, name);
            positionals[i] = .{
                .name = label,
                .value_type = values.valueType(values.Element(Field)),
                .choices = values.choices(values.Element(Field)),
                .required = !optional,
                .repeatable = list,
                .help = field_spec.help,
                .prompt = place.prompt,
                .value_name = values.label(values.Element(Field)),
                .check = values.checker(values.Element(Field)),
            };
            const has_choices = values.choices(values.Element(Field)).len > 0;
            if (place.complete != null or has_choices) any_complete = true;
        }
        const final = positionals;
        return .{
            .min = min,
            .max = max,
            .usage = usage,
            .complete = if (any_complete) typedCompleter(T, options) else null,
            .positionals = &final,
        };
    }
}

/// Completes each typed positional from its `.complete`, or from its enum's names.
fn typedCompleter(comptime T: type, comptime options: ArgOptions(T)) Command.Completer {
    const info = @typeInfo(T).@"struct";
    return &struct {
        fn call(ctx: *Context, prefix: []const u8) anyerror![]const Command.Candidate {
            const index = ctx.args.len;
            inline for (info.field_names, info.field_types, 0..) |name, Field, i| {
                const last = i + 1 == info.field_names.len;
                if (index == i or (last and index > i and values.isList(Field))) {
                    const place = comptime @field(options.fields, name);
                    if (comptime place.complete) |c| return c.call(ctx, prefix);
                    const names = comptime values.choices(values.Element(Field));
                    const out = try ctx.arena.alloc(Command.Candidate, names.len);
                    for (out, names) |*candidate, choice| candidate.* = .{ .value = choice };
                    return out;
                }
            }
            return &.{};
        }
    }.call;
}

const testing = std.testing;

const Tls = struct { cert: []const u8 = "", key: []const u8 = "" };
const Listener = struct { host: []const u8 = "0.0.0.0", port: u16 = 8080, tls: ?Tls = null };
const Example = struct {
    public: Listener = .{},
    storage: union(enum) {
        disk: struct { path: []const u8 = "/var" },
        s3: struct { bucket: []const u8 },
        memory,
    } = .memory,
    mirrors: []const Listener = &.{},
    tags: []const []const u8 = &.{},
    verbose: u8 = 0,
    json: bool = false,
    yaml: bool = false,
    token: []const u8,
    state: u8 = 0,
};

const example_specs = field.Set(.{
    field.Spec(Listener){ .fields = .{ .port = .{ .help = "Port", .checks = &.{.min(1)} } } },
    field.Spec(Example){ .fields = .{
        .tags = .{ .each = &.{.minLen(1)} },
        .token = .{ .secret = true },
    } },
});

const example = flags(Example, example_specs, .{
    .fields = .{
        .public = .{ .fields = .{ .port = .{ .short = 'p' } } },
        .mirrors = .{ .internal = true },
        .tags = .{ .name = "tag", .split = ',' },
        .verbose = .{ .short = 'v', .count = true },
        .json = .{ .requires = &.{.verbose} },
        .state = .{ .internal = true },
    },
    .exclusive = &.{&.{ .json, .yaml }},
});

test "groups flatten into prefixed names; choices name their variant" {
    const expected = [_][]const u8{
        "public-host", "public-port",       "public-tls-cert",   "public-tls-key",
        "storage",     "storage-disk-path", "storage-s3-bucket", "tag",
        "verbose",     "json",              "yaml",              "token",
    };
    try testing.expectEqual(expected.len, example.list.len);
    for (expected, example.list) |e, f| try testing.expectEqualStrings(e, f.name);
    try testing.expectEqualStrings("public.port", example.list[1].field);
    try testing.expectEqual('p', example.list[1].short.?);
    try testing.expectEqualStrings("Port", example.list[1].help);
    try testing.expectEqual(1, example.list[1].about.len);
    try testing.expectEqualStrings("disk|s3|memory", example.list[4].value_name);
    try testing.expectEqualStrings("storage", example.list[6].choice.?);
    try testing.expectEqualStrings("s3", example.list[6].variant);
    try testing.expect(!example.list[6].required);
    try testing.expect(example.list[11].required and example.list[11].secret);
    try testing.expectEqualStrings("verbose", example.list[9].requires[0]);
    try testing.expectEqualStrings("yaml", example.constraints.exclusive[0][1]);
    try testing.expectEqualStrings("public-tls", example.groups[1].prefix);
}

test "a value's checks, as typed" {
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var about: ?field.About = null;
    try example.list[1].validate.?("80", &w, &about);
    try testing.expectError(error.Invalid, example.list[1].validate.?("0", &w, &about));
    try testing.expectEqual(1, about.?.min.number.?);
    try testing.expectEqualStrings("must be at least 1", w.buffered());
    try testing.expectEqual(null, example.list[0].validate);
}

test "a group's separator and variables" {
    const Colors = struct { fg: []const u8 = "", bold: bool = false };
    const Flags = struct {
        limit: u8 = 1,
        dry_run: bool = false,
        cursor_style: Colors = .{},
        plain: Colors = .{},
        own: Colors = .{},
        storage: union(enum) { s3: struct { bucket: []const u8 = "" }, memory } = .memory,
    };
    const dotted: GroupPlace(Colors) = .{ .name = "cursor", .separator = "." };
    const set = flags(Flags, field.none, .{
        .env_prefix = "APP_",
        .fields = .{
            .dry_run = .{ .env = "DRY" },
            .cursor_style = dotted,
            .own = .{ .env_prefix = "MINE_", .fields = .{ .bold = .{ .env = "BOLD" } } },
        },
    });
    const expected = [_][2][]const u8{
        .{ "limit", "APP_LIMIT" },
        .{ "dry-run", "DRY" },
        .{ "cursor.fg", "APP_CURSOR_FG" },
        .{ "cursor.bold", "APP_CURSOR_BOLD" },
        .{ "plain-fg", "APP_PLAIN_FG" },
        .{ "plain-bold", "APP_PLAIN_BOLD" },
        .{ "own-fg", "MINE_FG" },
        .{ "own-bold", "BOLD" },
        .{ "storage", "APP_STORAGE" },
        .{ "storage-s3-bucket", "APP_STORAGE_S3_BUCKET" },
    };
    try testing.expectEqual(expected.len, set.list.len);
    for (expected, set.list) |e, f| {
        try testing.expectEqualStrings(e[0], f.name);
        try testing.expectEqualStrings(e[1], f.env.?);
    }
    try testing.expectEqualStrings("cursor_style.fg", set.list[2].field);
    try testing.expectEqualStrings("cursor", set.groups[0].prefix);
    // Without a prefix, only a flag's own `.env`.
    try testing.expectEqual(null, example.list[0].env);
}

const Copy = struct {
    source: []const u8,
    dest: ?[]const u8 = null,
    rest: []const []const u8 = &.{},
};

test "positionals from a struct" {
    const copy = args(Copy, field.Set(.{field.Spec(Copy){ .fields = .{
        .source = .{ .help = "File to copy" },
    } }}), .{ .fields = .{ .source = .{ .name = "src", .prompt = "Copy what?" } } });
    try testing.expectEqualStrings("<src> [dest] [rest...]", copy.command_args.usage);
    try testing.expectEqual(1, copy.command_args.min);
    try testing.expectEqual(null, copy.command_args.max);
    try testing.expectEqualStrings("File to copy", copy.command_args.positionals[0].help);
    try testing.expectEqualStrings("Copy what?", copy.command_args.positionals[0].prompt.?);
}
