//! Compile-error tests: each `<name>.zig` here declares a command the `cli` library must
//! reject at compile time. `zig build compile-errors` compiles every case on its own, with
//! the library as its only dependency, and expects exit status 1 and the message below on
//! standard error.

const std = @import("std");

const Case = struct {
    /// The file `test/compile_errors/<name>.zig`.
    name: []const u8,
    /// A substring of the compiler's error output.
    message: []const u8,
};

const cases = [_]Case{
    .{ .name = "unknown_spec_field", .message = "cli.command: unknown spec field 'sumary'" },
    .{ .name = "missing_name", .message = "cli.command: a command needs a .name" },
    .{ .name = "meta_unknown_field", .message = ".meta names no field 'prot'" },
    .{ .name = "count_not_integer", .message = "cli: .count needs an integer field: verbose" },
    .{ .name = "duplicate_long", .message = "cli: duplicate flag --port" },
    .{ .name = "duplicate_short", .message = "cli: duplicate short flag -p" },
    .{ .name = "help_reserved", .message = "cli: --help is reserved" },
    .{ .name = "duplicate_subcommand", .message = "cli: duplicate subcommand get" },
    .{ .name = "duplicate_alias", .message = "cli: duplicate subcommand rm" },
    .{
        .name = "constraint_unknown_flag",
        .message = "cli.command(\"app\"): constraint names unknown flag 'yml'",
    },
    .{
        .name = "handler_first_param",
        .message = "cli.command(\"app\"): a handler's first parameter must be *cli.Context",
    },
    .{
        .name = "handler_three_params",
        .message = "cli.command(\"app\"): " ++
            "a handler's third parameter must be the .args struct type",
    },
    .{
        .name = "handler_generic_flags",
        .message = "cli.command(\"app\"): a handler's flags parameter needs a concrete type",
    },
    .{
        .name = "unsupported_flag_type",
        .message = "cli: *const unsupported_flag_type.Point is not a supported flag type",
    },
    .{ .name = "flags_not_struct", .message = "cli: flags must be a struct, found u8" },
    .{ .name = "unknown_args_field", .message = "cli: unknown field 'maximum' in Command.Args" },
    .{ .name = "one_of_not_string", .message = "cli: .one_of needs a string field: level" },
    .{ .name = "bounds_not_numeric", .message = "cli: .min and .max need a numeric field: name" },
    .{
        .name = "validate_signature",
        .message = ".validate must be fn (validate_signature.Flags, *cli.Context) !void",
    },
    .{
        .name = "args_required_after_optional",
        .message = "cli.command(\"app\"): required positional second follows an optional one",
    },
    .{
        .name = "args_list_not_last",
        .message = "cli.command(\"app\"): only the last positional may be a list: files",
    },
    .{
        .name = "completer_signature",
        .message = ".complete must be fn (*cli.Context, []const u8) ![]const cli.Candidate",
    },
    // `cfg`: `.zon` defaults are checked against the settings struct when imported.
    .{ .name = "zon_defaults_unknown_field", .message = "unexpected field 'prot'" },
    .{ .name = "zon_defaults_wrong_type", .message = "expected type 'u16'" },
};

/// Adds one `zig build-obj` run per case to `step`.
pub fn addCases(b: *std.Build, step: *std.Build.Step) void {
    const cli_root = b.path("src/cli/root.zig");
    const term_root = b.path("src/term/root.zig");
    const local_cache: std.Build.LazyPath = .{ .relative = .{ .base = .local_cache } };
    const global_cache: std.Build.LazyPath = .{ .relative = .{ .base = .global_cache } };
    for (cases) |case| {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build-obj", "-fno-emit-bin" });
        run.setName(b.fmt("compile error: {s}", .{case.name}));
        run.addArg("--zig-lib-dir");
        run.addDirectoryArg(.zig_lib);
        run.addArg("--cache-dir");
        run.addDirectoryArg(local_cache);
        run.addArg("--global-cache-dir");
        run.addDirectoryArg(global_cache);
        run.addArgs(&.{ "--dep", "cli" });
        run.addPrefixedFileArg("-Mroot=", b.path(b.fmt("test/compile_errors/{s}.zig", .{
            case.name,
        })));
        run.addArgs(&.{ "--dep", "term" });
        run.addPrefixedFileArg("-Mcli=", cli_root);
        run.addPrefixedFileArg("-Mterm=", term_root);
        // The library's other files are inputs too, but are not named on the command line;
        // rerunning every time is cheaper than keeping a list of them here.
        run.has_side_effects = true;
        run.expectStdErrMatch(case.message);
        run.expectExitCode(1);
        step.dependOn(&run.step);
    }
}
