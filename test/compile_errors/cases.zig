//! Compile-error tests: each `<name>.zig` here declares a command the `cli` library (or a
//! model the `tui` one) must reject at compile time. `zig build compile-errors` compiles
//! every case on its own, with the libraries as its only dependencies, and expects exit
//! status 1 and the message below on standard error.

const std = @import("std");

const Case = struct {
    /// The file `test/compile_errors/<name>.zig`.
    name: []const u8,
    /// A substring of the compiler's error output.
    message: []const u8,
};

const cases = [_]Case{
    .{
        .name = "unknown_spec_field",
        .message = "cli.command(\"app\"): unknown spec field 'sumary'; did you mean 'summary'?",
    },
    .{ .name = "missing_name", .message = "cli.command: a command needs a .name" },
    .{
        .name = "meta_unknown_field",
        .message = "cli.command(\"app\"): meta_unknown_field.Flags.meta names no field 'prot'" ++
            "; did you mean 'port'? (fields: port, host)",
    },
    .{
        .name = "meta_unknown_field_far",
        .message = "cli: meta_unknown_field_far.Flags.meta names no field 'zzz' (fields: port)",
    },
    .{ .name = "count_not_integer", .message = "cli: .count needs an integer field: verbose" },
    .{ .name = "duplicate_long", .message = "cli: duplicate flag --port" },
    .{ .name = "duplicate_short", .message = "cli: duplicate short flag -p" },
    .{ .name = "help_reserved", .message = "cli: --help is reserved" },
    .{ .name = "duplicate_subcommand", .message = "cli: duplicate subcommand get" },
    .{ .name = "duplicate_alias", .message = "cli: duplicate subcommand rm" },
    .{
        .name = "constraint_unknown_flag",
        .message = "cli.command(\"app\"): constraint names unknown flag 'yml'" ++
            "; did you mean 'yaml'?",
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
    .{
        .name = "unknown_args_field",
        .message = "cli.command(\"app\"): unknown field 'maxx' in Command.Args" ++
            "; did you mean 'max'?",
    },
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
    // `tui`: the test driver frees a model only through a `deinit` it can call.
    .{
        .name = "driver_deinit_signature",
        .message = "tui.testing.Driver(driver_deinit_signature.Model): deinit must be " ++
            "fn (*driver_deinit_signature.Model) void or " ++
            "fn (*driver_deinit_signature.Model, std.mem.Allocator) void, " ++
            "found fn (*driver_deinit_signature.Model, u8) void",
    },
};

/// Adds one `zig build-obj` run per case to `step`.
pub fn addCases(b: *std.Build, step: *std.Build.Step) void {
    const cli_root = b.path("src/cli/root.zig");
    const term_root = b.path("src/term/root.zig");
    const tui_root = b.path("src/tui/root.zig");
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
        run.addArgs(&.{ "--dep", "cli", "--dep", "tui" });
        run.addPrefixedFileArg("-Mroot=", b.path(b.fmt("test/compile_errors/{s}.zig", .{
            case.name,
        })));
        run.addArgs(&.{ "--dep", "term" });
        run.addPrefixedFileArg("-Mcli=", cli_root);
        run.addArgs(&.{ "--dep", "term" });
        run.addPrefixedFileArg("-Mtui=", tui_root);
        run.addPrefixedFileArg("-Mterm=", term_root);
        // The library's other files are inputs too, but are not named on the command line;
        // rerunning every time is cheaper than keeping a list of them here.
        run.has_side_effects = true;
        run.expectStdErrMatch(case.message);
        run.expectExitCode(1);
        step.dependOn(&run.step);
    }
}
