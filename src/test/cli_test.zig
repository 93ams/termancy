const std = @import("std");
const testing = std.testing;
const cli = @import("framework");

const App = cli.App(usize, .{});

// --- Mocks ---

const LoginFlags = struct {
    token: []const u8,
    ttl: u32 = 3600,

    pub const meta = .{
        .token = .{ .short = 't' },
    };
};

const LoginCmd = App.LeafCommand(LoginFlags){
    .name = "login",
    .description = "Login to the system",
    .run = loginRun,
};

fn loginRun(ctx: App.Ctx, flags: App.Flags(LoginFlags)) !void {
    _ = ctx;
    _ = flags;
}

const LogoutFlags = struct {
    force: bool = false,
    all: bool = false,

    pub const meta = .{
        .force = .{ .short = 'f' },
        .all = .{ .short = 'a' },
    };
};

const LogoutCmd = App.LeafCommand(LogoutFlags){
    .name = "logout",
    .description = "Logout from the system",
    .run = logoutRun,
};

fn logoutRun(ctx: App.Ctx, flags: App.Flags(LogoutFlags)) !void {
    _ = ctx;
    _ = flags;
}

const AuthFlags = struct {};

const AuthCmd = .{
    .name = "auth",
    .description = "Authentication commands",
    .run = authRun,
    .subcommands = .{
        LoginCmd,
        LogoutCmd,
    },
};

fn authRun(ctx: App.Ctx, flags: AuthFlags) !void {
    _ = ctx;
    _ = flags;
}

const RootFlags = struct {
    verbose: bool = false,
    mode: enum { prod, dev, @"test" } = .prod,

    pub const meta = .{
        .verbose = .{ .short = 'v' },
    };
};

const RootCmd = .{
    .name = "mycli",
    .description = "Root command",
    .run = rootRun,
    .subcommands = .{
        AuthCmd,
    },
};

fn rootRun(ctx: App.Ctx, flags: RootFlags) !void {
    _ = ctx;
    _ = flags;
}

// --- Test Helper ---
//
// `io` is `std.testing.io` here and at every other hand-built `App.Ctx` in this file, not
// `undefined` (S-7). `undefined` is not a compile error for a `std.Io` - it is a trap door:
// every platform helper in the library takes `ctx.io` (`state.zig` opens files with it,
// `cli.zig` spawns with it), so a test that reached one of those paths got a garbage vtable
// read rather than a diagnostic. The commands these helpers drive today happen to be
// output-only, which is the only reason it never fired. `TestHarness` had it right, with a
// comment saying why; the hand-built contexts now match.

fn testExecute(args: [][]const u8, out_fbs: *std.Io.Writer, err_fbs: *std.Io.Writer) !void {
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var dummy_state: usize = 0;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = out_fbs,
        .err = err_fbs,
        .state = &dummy_state,
        .env_map = &env_map,
        .io = std.testing.io,
    };
    var pre_runs: [32]?*const fn (ctx: App.Ctx) App.Error!void = undefined;
    @memset(&pre_runs, null);
    var post_runs: [32]?*const fn (ctx: App.Ctx) App.Error!void = undefined;
    @memset(&post_runs, null);
    var chain = App.ExecutionChain{ .pre_runs = &pre_runs, .post_runs = &post_runs };
    try App.execute(RootCmd, ctx, args, &chain);
}

// --- Tests ---

test "Happy Path: Deeply nested subcommand routing and flag parsing" {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);

    var args = [_][]const u8{ "auth", "login", "--token", "secure_abc123", "--ttl", "120" };
    try testExecute(&args, &out, &err);

    try testing.expectEqualStrings("", err_buf[0 .. err_buf.len - err.unusedCapacityLen()]);
}

test "Short Flags: Grouping (-fa resolving to multiple booleans)" {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);

    var args = [_][]const u8{ "auth", "logout", "-fa" };
    try testExecute(&args, &out, &err);

    try testing.expectEqualStrings("", err_buf[0 .. err_buf.len - err.unusedCapacityLen()]);
}

test "Validation Failure: Missing required flags" {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);

    var args = [_][]const u8{ "auth", "login" };
    const result = testExecute(&args, &out, &err);

    try testing.expectError(error.MissingRequiredFlag, result);
    try testing.expect(std.mem.indexOf(u8, err_buf[0 .. err_buf.len - err.unusedCapacityLen()], "Error: Missing required flag '--token'") != null);
}

test "Validation Failure: Invalid enum type" {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);

    var args = [_][]const u8{ "--mode", "invalid_mode" };
    const result = testExecute(&args, &out, &err);

    try testing.expectError(error.HandledError, result);
    try testing.expect(std.mem.indexOf(u8, err_buf[0 .. err_buf.len - err.unusedCapacityLen()], "Error: Invalid value 'invalid_mode' for flag '--mode'") != null);
}

test "Validation Failure: Unrecognized argument" {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);

    var args = [_][]const u8{"--unknown"};
    const result = testExecute(&args, &out, &err);

    try testing.expectError(error.UnknownFlag, result);
    try testing.expect(std.mem.indexOf(u8, err_buf[0 .. err_buf.len - err.unusedCapacityLen()], "Error: Unknown flag 'unknown'") != null);
}

test "Help Text: Passing --help triggers comptime-generated usage string" {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);

    var args = [_][]const u8{"--help"};
    try testExecute(&args, &out, &err);

    const output = out_buf[0 .. out_buf.len - out.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, output, "Usage: mycli [command]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Root command") != null);
    // Aligned rows rather than tab-separated ones: the descriptions of two commands
    // now start in the same column, which a tab stop cannot guarantee.
    try testing.expect(std.mem.indexOf(u8, output, "  auth  Authentication commands") != null);
    try testing.expect(std.mem.indexOf(u8, output, "--verbose, -v") != null);

    var out2_buf: [4096]u8 = undefined;
    var out2 = std.Io.Writer.fixed(&out2_buf);
    _ = &out2;
    var err2_buf: [4096]u8 = undefined;
    var err2 = std.Io.Writer.fixed(&err2_buf);
    _ = &err2;

    var args2 = [_][]const u8{ "auth", "login", "--token", "foo", "--help" };
    try testExecute(&args2, &out2, &err2);

    try testing.expect(std.mem.indexOf(u8, out2_buf[0 .. out2_buf.len - out2.unusedCapacityLen()], "--token, -t") != null);
}

test "Zero-Copy Verification" {
    var captured_addr: usize = 0;
    _ = &captured_addr;

    const ZeroFlags = struct {
        file: []const u8,
    };

    const TestRun = struct {
        fn do(ctx: App.Ctx, flags: App.Flags(ZeroFlags)) !void {
            ctx.state.* = @intFromPtr(flags.file.ptr);
        }
    };

    const ZeroCmd = App.LeafCommand(ZeroFlags){
        .name = "zero",
        .run = TestRun.do,
    };

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &captured_addr,
        .env_map = &env_map,
        .io = std.testing.io,
    };

    const target_string = "path/to/some_file.txt";
    var args = [_][]const u8{ "--file", target_string };

    var pre_runs: [32]?*const fn (ctx: App.Ctx) App.Error!void = undefined;
    @memset(&pre_runs, null);
    var post_runs: [32]?*const fn (ctx: App.Ctx) App.Error!void = undefined;
    @memset(&post_runs, null);
    var chain = App.ExecutionChain{ .pre_runs = &pre_runs, .post_runs = &post_runs };
    try App.execute(ZeroCmd, ctx, &args, &chain);

    const original_addr = @intFromPtr(target_string.ptr);
    try testing.expectEqual(original_addr, captured_addr);
}

const MyIp = struct {};
fn parseIp(val: []const u8) !MyIp {
    if (val.len > 0) return MyIp{};
    return error.InvalidIP;
}
fn validatePort(val: u16) !void {
    if (val < 1024) return error.PrivilegedPort;
}

const CustomFlags = struct {
    ip: MyIp,
    port: u16 = 8080,

    pub const meta = .{
        .port = .{ .validate = validatePort },
    };
};

const CustomCmd = App.CommandWithReturn(CustomFlags, void, .{}){
    .name = "custom",
    .run = customRun,
};

fn customRun(ctx: App.Ctx, flags: App.Flags(CustomFlags)) !void {
    _ = ctx;
    _ = flags;
}

test "Custom Parser and Validator" {
    const CustomApp = cli.App(usize, .{ .type_parsers = .{parseIp} });
    var out_buf: [4096]u8 = undefined;
    var out_fbs = std.Io.Writer.fixed(&out_buf);
    var err_buf: [4096]u8 = undefined;
    var err_fbs = std.Io.Writer.fixed(&err_buf);
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    var args = [_][]const u8{ "custom", "--ip", "127.0.0.1", "--port", "80" };
    var dummy_state: usize = 0;
    const ctx = CustomApp.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out_fbs,
        .err = &err_fbs,
        .state = &dummy_state,
        .env_map = &env_map,
        .io = std.testing.io,
    };
    var chain = try CustomApp.ExecutionChain.init(testing.allocator, args.len);
    defer chain.deinit(testing.allocator);

    const result = CustomApp.execute(CustomCmd, ctx, &args, &chain);
    try testing.expectError(error.PrivilegedPort, result);
}

// --- Module 1: Global Middleware (Onion Architecture) ---

var mw_trace: [4]u8 = @splat(0);
var mw_trace_count: usize = 0;

fn traceMiddleware1(ctx: anytype, next: anytype) !void {
    _ = ctx;
    mw_trace[mw_trace_count] = 1;
    mw_trace_count += 1;
    try next.call();
    mw_trace[mw_trace_count] = 4;
    mw_trace_count += 1;
}

fn traceMiddleware2(ctx: anytype, next: anytype) !void {
    _ = ctx;
    mw_trace[mw_trace_count] = 2;
    mw_trace_count += 1;
    try next.call();
    mw_trace[mw_trace_count] = 3;
    mw_trace_count += 1;
}

test "Global Middleware: Onion Architecture execution order" {
    mw_trace_count = 0;
    const MwApp = cli.App(usize, .{
        .middlewares = .{ traceMiddleware1, traceMiddleware2 },
    });

    const MwFlags = struct {};
    const MwCmd = MwApp.LeafCommand(MwFlags){
        .name = "test_mw",
        .run = struct {
            fn do(_: MwApp.Ctx, _: MwApp.Flags(MwFlags)) !void {}
        }.do,
    };

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var dummy_state: usize = 0;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const ctx = MwApp.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &dummy_state,
        .env_map = &env_map,
        .io = std.testing.io,
    };

    var chain = try MwApp.ExecutionChain.init(testing.allocator, 1);
    defer chain.deinit(testing.allocator);

    var args = [_][]const u8{};
    try MwApp.execute(MwCmd, ctx, &args, &chain);

    // Verify onion order: MW1 enter (1) -> MW2 enter (2) -> command -> MW2 exit (3) -> MW1 exit (4)
    try testing.expectEqual(@as(usize, 4), mw_trace_count);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, mw_trace[0..4]);
}

test "Structured POSIX Exit Codes" {
    const ExitApp = cli.App(usize, .{
        .exit_map = &.{
            .{ .name = "CustomError", .code = 42 },
        },
    });

    // Check custom exit code mapping
    try testing.expectEqual(@as(u8, 42), ExitApp.getExitCode(error.CustomError));

    // Check POSIX defaults
    try testing.expectEqual(@as(u8, 127), ExitApp.getExitCode(error.UnknownCommand));
    try testing.expectEqual(@as(u8, 126), ExitApp.getExitCode(error.CommandNotExecutable));
    try testing.expectEqual(@as(u8, 2), ExitApp.getExitCode(error.MissingRequiredFlag));
    try testing.expectEqual(@as(u8, 2), ExitApp.getExitCode(error.ConflictingFlags));
    try testing.expectEqual(@as(u8, 2), ExitApp.getExitCode(error.DependentFlagMissing));
    try testing.expectEqual(@as(u8, 1), ExitApp.getExitCode(error.OutOfMemory));
}

// --- Module 8: Advanced Argument & Flag Semantics ---

test "End-of-Options Delimiter (--)" {
    const PosFlags = struct {
        positionals: struct {
            first: []const u8 = "",
            second: []const u8 = "",
        } = .{},
        flag: bool = false,
    };

    const PosCmd = App.LeafCommand(PosFlags){
        .name = "pos_cmd",
        .run = struct {
            fn do(ctx: App.Ctx, flags: App.Flags(PosFlags)) !void {
                try ctx.out.print("{s}|{s}|{}", .{ flags.positionals.first, flags.positionals.second, flags.flag });
            }
        }.do,
    };

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var dummy: usize = 0;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &dummy,
        .env_map = &env_map,
        .io = std.testing.io,
    };

    var chain = try App.ExecutionChain.init(testing.allocator, 4);
    defer chain.deinit(testing.allocator);

    // Anything after bare '--' is treated as positional, even if prefixed with '--'
    var args = [_][]const u8{ "--", "--flag", "file2.txt" };
    try App.execute(PosCmd, ctx, &args, &chain);

    const written = out_buf[0 .. out_buf.len - out.unusedCapacityLen()];
    try testing.expectEqualStrings("--flag|file2.txt|false", written);
}

test "Negatable Boolean Flags (--no-*)" {
    const CacheFlags = struct {
        cache: bool = true,
    };

    const CacheCmd = App.LeafCommand(CacheFlags){
        .name = "cache_cmd",
        .run = struct {
            fn do(ctx: App.Ctx, flags: App.Flags(CacheFlags)) !void {
                ctx.state.* = if (flags.cache) 1 else 0;
            }
        }.do,
    };

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var dummy: usize = 999;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &dummy,
        .env_map = &env_map,
        .io = std.testing.io,
    };

    var chain = try App.ExecutionChain.init(testing.allocator, 1);
    defer chain.deinit(testing.allocator);

    var args = [_][]const u8{"--no-cache"};
    try App.execute(CacheCmd, ctx, &args, &chain);

    try testing.expectEqual(@as(usize, 0), dummy);
}

test "Cumulative / Count Flags (-vvv)" {
    const CountFlags = struct {
        verbose: u8 = 0,

        pub const meta = .{
            .verbose = .{ .short = 'v', .count = true },
        };
    };

    const CountCmd = App.LeafCommand(CountFlags){
        .name = "count_cmd",
        .run = struct {
            fn do(ctx: App.Ctx, flags: App.Flags(CountFlags)) !void {
                ctx.state.* = flags.verbose;
            }
        }.do,
    };

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var dummy: usize = 0;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &dummy,
        .env_map = &env_map,
        .io = std.testing.io,
    };

    var chain = try App.ExecutionChain.init(testing.allocator, 1);
    defer chain.deinit(testing.allocator);

    var args = [_][]const u8{"-vvv"};
    try App.execute(CountCmd, ctx, &args, &chain);

    try testing.expectEqual(@as(usize, 3), dummy);
}

test "Direct Environment Variable Binding in Flags" {
    const EnvFlags = struct {
        port: u16 = 3000,

        pub const meta = .{
            .port = .{ .env = "PORT" },
        };
    };

    const EnvCmd = App.LeafCommand(EnvFlags){
        .name = "env_cmd",
        .run = struct {
            fn do(ctx: App.Ctx, flags: App.Flags(EnvFlags)) !void {
                ctx.state.* = flags.port;
            }
        }.do,
    };

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var dummy: usize = 0;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    try env_map.put("PORT", "8080");

    const ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &dummy,
        .env_map = &env_map,
        .io = std.testing.io,
    };

    var chain = try App.ExecutionChain.init(testing.allocator, 1);
    defer chain.deinit(testing.allocator);

    // Omit --port on CLI; should pick up from PORT=8080 in env_map
    var args = [_][]const u8{};
    try App.execute(EnvCmd, ctx, &args, &chain);

    try testing.expectEqual(@as(usize, 8080), dummy);
}

test "Mutual Exclusion (conflicts_with)" {
    const ConflictFlags = struct {
        json: bool = false,
        csv: bool = false,

        pub const meta = .{
            .json = .{ .conflicts_with = &.{"csv"} },
        };
    };

    const ConflictCmd = App.LeafCommand(ConflictFlags){
        .name = "conflict_cmd",
        .run = struct {
            fn do(_: App.Ctx, _: App.Flags(ConflictFlags)) !void {}
        }.do,
    };

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var dummy: usize = 0;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &dummy,
        .env_map = &env_map,
        .io = std.testing.io,
    };

    var chain = try App.ExecutionChain.init(testing.allocator, 2);
    defer chain.deinit(testing.allocator);

    var args = [_][]const u8{ "--json", "--csv" };
    const result = App.execute(ConflictCmd, ctx, &args, &chain);

    try testing.expectError(error.ConflictingFlags, result);
}

test "Co-requisite Flags (requires)" {
    const ReqFlags = struct {
        auth_token: ?[]const u8 = null,
        auth_url: ?[]const u8 = null,

        pub const meta = .{
            .auth_token = .{ .requires = &.{"auth_url"} },
        };
    };

    const ReqCmd = App.LeafCommand(ReqFlags){
        .name = "req_cmd",
        .run = struct {
            fn do(_: App.Ctx, _: App.Flags(ReqFlags)) !void {}
        }.do,
    };

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var dummy: usize = 0;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &dummy,
        .env_map = &env_map,
        .io = std.testing.io,
    };

    var chain = try App.ExecutionChain.init(testing.allocator, 2);
    defer chain.deinit(testing.allocator);

    // Provide --auth-token without --auth-url
    var args = [_][]const u8{ "--auth_token", "secret123" };
    const result = App.execute(ReqCmd, ctx, &args, &chain);

    try testing.expectError(error.DependentFlagMissing, result);
}

test "Hidden / Deprecated Flag Lifecycle" {
    const DepFlags = struct {
        old_flag: bool = false,
        new_flag: bool = false,

        pub const meta = .{
            .old_flag = .{ .deprecated = "use --new_flag instead" },
        };
    };

    const DepCmd = App.LeafCommand(DepFlags){
        .name = "dep_cmd",
        .run = struct {
            fn do(_: App.Ctx, _: App.Flags(DepFlags)) !void {}
        }.do,
    };

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var dummy: usize = 0;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &dummy,
        .env_map = &env_map,
        .io = std.testing.io,
    };

    // 1. Using deprecated flag should print a warning to stderr
    var chain = try App.ExecutionChain.init(testing.allocator, 1);
    defer chain.deinit(testing.allocator);

    var args = [_][]const u8{"--old_flag"};
    try App.execute(DepCmd, ctx, &args, &chain);

    const err_output = err_buf[0 .. err_buf.len - err.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, err_output, "Warning: Flag '--old_flag' is deprecated: use --new_flag instead") != null);

    // 2. Help should NOT list --old_flag
    var out_help_buf: [1024]u8 = undefined;
    var out_help = std.Io.Writer.fixed(&out_help_buf);
    var err_help_buf: [1024]u8 = undefined;
    var err_help = std.Io.Writer.fixed(&err_help_buf);
    const help_ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out_help,
        .err = &err_help,
        .state = &dummy,
        .env_map = &env_map,
        .io = std.testing.io,
    };

    var chain_help = try App.ExecutionChain.init(testing.allocator, 1);
    defer chain_help.deinit(testing.allocator);

    var help_args = [_][]const u8{"--help"};
    try App.execute(DepCmd, help_ctx, &help_args, &chain_help);

    const help_output = out_help_buf[0 .. out_help_buf.len - out_help.unusedCapacityLen()];
    // Help renders the command-line spelling, so a field named `new_flag` is
    // advertised as `--new-flag`; the underscore spelling still parses.
    try testing.expect(std.mem.indexOf(u8, help_output, "--old-flag") == null);
    try testing.expect(std.mem.indexOf(u8, help_output, "--new-flag") != null);
}

test "Typo Correction: Levenshtein distance suggestions on UnknownCommand" {
    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var dummy: usize = 0;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &dummy,
        .env_map = &env_map,
        .io = std.testing.io,
    };

    const TestRootCmd1 = struct {
        pub const subcommands = .{ LoginCmd, LogoutCmd };
        name: []const u8 = "root",
        description: []const u8 = "root command",
    }{};

    var chain = try App.ExecutionChain.init(testing.allocator, 1);
    defer chain.deinit(testing.allocator);

    // Type 'logni' instead of 'login'
    var args = [_][]const u8{"logni"};
    const result = App.execute(TestRootCmd1, ctx, &args, &chain);
    try testing.expectError(error.UnknownCommand, result);

    const err_output = err_buf[0 .. err_buf.len - err.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, err_output, "Did you mean 'login'?") != null);
}

test "In-Memory Testing Harness: TestHarness execution without sub-processes" {
    var harness = App.TestHarness.init(testing.allocator);
    defer harness.deinit();

    var dummy: usize = 0;
    const TestRootCmd2 = struct {
        pub const subcommands = .{ LoginCmd, LogoutCmd };
        name: []const u8 = "root",
        description: []const u8 = "root command",
    }{};

    var args = [_][]const u8{ "login", "--token", "secret123" };
    try harness.run(&dummy, TestRootCmd2, &args);

    // LoginCmd ran cleanly with in-memory harness
    try testing.expectEqual(@as(usize, 0), harness.err_buf.items.len);
}

test "Terminal Graphics & Formatting: OSC 8 Hyperlinks & Terminal Diff Viewer" {
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    // Hyperlinks
    try cli.style.hyperlink(&out, "https://ziglang.org", "Zig Website");
    const link_out = out_buf[0 .. out_buf.len - out.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, link_out, "\x1b]8;;https://ziglang.org\x1b\\Zig Website\x1b]8;;\x1b\\") != null);

    // Diff Viewer
    var diff_buf: [1024]u8 = undefined;
    var diff_out = std.Io.Writer.fixed(&diff_buf);
    const old_txt = "hello\nworld\nfoo";
    const new_txt = "hello\nearth\nfoo";
    try cli.style.renderDiff(&diff_out, old_txt, new_txt);

    const diff_str = diff_buf[0 .. diff_buf.len - diff_out.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, diff_str, "  hello") != null);
    try testing.expect(std.mem.indexOf(u8, diff_str, "- world") != null);
    try testing.expect(std.mem.indexOf(u8, diff_str, "+ earth") != null);
}

test "Terminal Graphics & Formatting: Advanced Table Engine" {
    var table_buf: [2048]u8 = undefined;
    var table_out = std.Io.Writer.fixed(&table_buf);

    const cols = [_]cli.style.Column{
        .{ .header = "Name", .alignment = .left },
        .{ .header = "Role", .alignment = .center },
        .{ .header = "Status", .alignment = .right },
    };
    const row1 = [_][]const u8{ "Alice", "Admin", "Active" };
    const row2 = [_][]const u8{ "Bob", "User", "Pending" };
    const rows = [_][]const []const u8{ &row1, &row2 };

    const table = cli.style.Table{
        .columns = &cols,
        .rows = &rows,
        .border = .rounded,
        .padding = 1,
    };

    try table.render(&table_out);

    const table_str = table_buf[0 .. table_buf.len - table_out.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, table_str, "╭") != null);
    try testing.expect(std.mem.indexOf(u8, table_str, "Alice") != null);
    try testing.expect(std.mem.indexOf(u8, table_str, "Bob") != null);
    try testing.expect(std.mem.indexOf(u8, table_str, "╰") != null);
}

test "Terminal Graphics & Formatting: Micro Syntax Highlighter" {
    var hl_buf: [1024]u8 = undefined;
    var hl_out = std.Io.Writer.fixed(&hl_buf);

    const sample = "const count = 42; // comment\nconst name = \"snek\";";
    try cli.style.highlight(&hl_out, sample);

    const hl_str = hl_buf[0 .. hl_buf.len - hl_out.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, hl_str, "\x1b[35mconst\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, hl_str, "\x1b[33m42\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, hl_str, "\x1b[2m// comment\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, hl_str, "\x1b[32m\"snek\"\x1b[0m") != null);
}

test "i18n: Locale resolution, dictionary fallback, and string interpolation" {
    var translator = cli.i18n.init(testing.allocator, "en_US");
    defer translator.deinit();

    const en_entries = [_]struct { []const u8, []const u8 }{
        .{ "greeting", "Hello, {name}! You have {count} messages." },
        .{ "farewell", "Goodbye, {name}!" },
    };
    try translator.addTranslations("en", &en_entries);

    const es_entries = [_]struct { []const u8, []const u8 }{
        .{ "greeting", "¡Hola, {name}! Tienes {count} mensajes." },
    };
    try translator.addTranslations("es", &es_entries);

    // 1. English rendering
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try translator.format(&writer, "greeting", .{ .name = "Alice", .count = @as(u32, 5) });
    const en_res = buf[0 .. buf.len - writer.unusedCapacityLen()];
    try testing.expectEqualStrings("Hello, Alice! You have 5 messages.", en_res);

    // 2. Spanish rendering
    translator.setLocale("es_ES");
    var es_buf: [256]u8 = undefined;
    var es_writer = std.Io.Writer.fixed(&es_buf);
    try translator.format(&es_writer, "greeting", .{ .name = "Carlos", .count = @as(u32, 12) });
    const es_res = es_buf[0 .. es_buf.len - es_writer.unusedCapacityLen()];
    try testing.expectEqualStrings("¡Hola, Carlos! Tienes 12 mensajes.", es_res);

    // 3. Fallback to English for missing key
    var fb_buf: [256]u8 = undefined;
    var fb_writer = std.Io.Writer.fixed(&fb_buf);
    try translator.format(&fb_writer, "farewell", .{ .name = "Carlos" });
    const fb_res = fb_buf[0 .. fb_buf.len - fb_writer.unusedCapacityLen()];
    try testing.expectEqualStrings("Goodbye, Carlos!", fb_res);
}

test "Pager: Terminal line counting threshold detection" {
    // `pager` is still a wrapped module (its conversion is blocked on a stale
    // `std.process.Child.init` call), so the type name is still required here.
    const short_text = "line 1\nline 2\nline 3\n";
    try testing.expect(!cli.pager.shouldPage(short_text, 10));

    const long_text = "l1\nl2\nl3\nl4\nl5\nl6\n";
    try testing.expect(cli.pager.shouldPage(long_text, 4));
}

test "Panic: Structured Panic Boxed Rendering" {
    var panic_buf: [4096]u8 = undefined;
    var panic_out = std.Io.Writer.fixed(&panic_buf);

    cli.panic.renderStructuredPanic(&panic_out, "Null pointer dereference in auth handler", null, .{
        .app_name = "snek",
        .issues_url = "https://github.com/93ams/snek/issues",
        .cache_dir = ".cache/crashes",
    });

    const rendered = panic_buf[0 .. panic_buf.len - panic_out.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, rendered, "UNEXPECTED FATAL ERROR") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Null pointer dereference") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "github.com/93ams/snek/issues") != null);
}

test "Multi-Bar Progress: Concurrent bar updates and progress tracking" {
    var mp = cli.progress.MultiProgress.init(testing.allocator);
    defer mp.deinit();

    const bar1 = try mp.addBar("Component A", 100);
    const bar2 = try mp.addBar("Component B", 200);

    mp.update(bar1, 50);
    mp.update(bar2, 200);

    try testing.expect(!mp.isAllDone());

    var render_buf: [1024]u8 = undefined;
    var render_out = std.Io.Writer.fixed(&render_buf);
    try mp.render(&render_out);

    const rendered = render_buf[0 .. render_buf.len - render_out.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, rendered, "Component A") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Component B") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "50%") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "100%") != null);

    mp.update(bar1, 50);
    try testing.expect(mp.isAllDone());
}

test "Widgets: Unified Focus Manager tab order" {
    var focus = cli.widgets.FocusManager.init(3);
    try testing.expect(focus.isFocused(0));
    try testing.expect(!focus.isFocused(1));

    focus.next();
    try testing.expect(focus.isFocused(1));

    focus.next();
    try testing.expect(focus.isFocused(2));

    focus.next();
    try testing.expect(focus.isFocused(0)); // Wrapped around

    focus.prev();
    try testing.expect(focus.isFocused(2)); // Wrapped back
}

test "Widgets: System Clipboard Integration via OSC 52" {
    var clip_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&clip_buf);

    try cli.widgets.copyToClipboard(&writer, "Snek CLI", testing.allocator);
    const clip_out = clip_buf[0 .. clip_buf.len - writer.unusedCapacityLen()];

    // Base64 of "Snek CLI" is "U25layBDTEk="
    try testing.expect(std.mem.indexOf(u8, clip_out, "\x1b]52;c;U25layBDTEk=\x07") != null);
}

test "Widgets: Fuzzy Finder scoring" {
    // A path in this tree, so the fixture is a real one rather than a plausible string.
    const target = "src/lib/render/tea.zig";

    const match1 = cli.widgets.fuzzyScore("tea", target);
    try testing.expect(match1 != null);
    try testing.expect(match1.?.score > 0);

    const match2 = cli.widgets.fuzzyScore("xyz", target);
    try testing.expect(match2 == null);
}

test "Widgets: Interactive Hotkey Overlay" {
    var overlay_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&overlay_buf);

    const bindings = [_]cli.widgets.Keybinding{
        .{ .key = "?", .desc = "Toggle help overlay" },
        .{ .key = "q / Ctrl+C", .desc = "Quit application" },
    };

    try cli.widgets.renderHotkeyOverlay(&writer, "Keyboard Shortcuts", &bindings);
    const overlay_out = overlay_buf[0 .. overlay_buf.len - writer.unusedCapacityLen()];

    try testing.expect(std.mem.indexOf(u8, overlay_out, "Keyboard Shortcuts") != null);
    try testing.expect(std.mem.indexOf(u8, overlay_out, "Toggle help overlay") != null);
    try testing.expect(std.mem.indexOf(u8, overlay_out, "Quit application") != null);
}

test "Widgets: Live Form Engine with password masking" {
    var fields = [_]cli.widgets.FormField{
        .{ .label = "Username", .field_type = .text },
        .{ .label = "Password", .field_type = .password },
    };
    fields[0].setValue("admin");
    fields[1].setValue("secret_pass");

    const form = cli.widgets.Form.init(&fields);

    var form_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&form_buf);

    try form.render(&writer);
    const form_out = form_buf[0 .. form_buf.len - writer.unusedCapacityLen()];

    try testing.expect(std.mem.indexOf(u8, form_out, "Username:") != null);
    try testing.expect(std.mem.indexOf(u8, form_out, "admin") != null);
    try testing.expect(std.mem.indexOf(u8, form_out, "Password:") != null);
    try testing.expect(std.mem.indexOf(u8, form_out, "secret_pass") == null); // Secret must be masked!
    try testing.expect(std.mem.indexOf(u8, form_out, "***********") != null); // 11 asterisks
}

test "System: Desktop notifications via OSC 777 and OSC 9" {
    var notif_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&notif_buf);

    try cli.sys.System.notifyTerminal(&writer, "Build Complete", "All artifacts built");
    const notif_out = notif_buf[0 .. notif_buf.len - writer.unusedCapacityLen()];

    try testing.expect(std.mem.indexOf(u8, notif_out, "\x1b]777;notify;Build Complete;All artifacts built\x1b\\") != null);
    try testing.expect(std.mem.indexOf(u8, notif_out, "\x1b]9;All artifacts built\x1b\\") != null);
}

test "Security: Memory Zeroization and Redaction" {
    // 1. Wipe test
    var secret_data = [_]u8{ 's', 'u', 'p', 'e', 'r', '_', 'k', 'e', 'y' };
    cli.security.wipe(&secret_data);
    for (secret_data) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }

    // 2. Redaction test
    var red_buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&red_buf);
    try cli.security.redact(&writer, "secret12345");
    const red_out = red_buf[0 .. red_buf.len - writer.unusedCapacityLen()];
    try testing.expectEqualStrings("s*********5", red_out);
}

test "Telemetry: W3C Distributed Tracing traceparent generation" {
    const tp = cli.trace_parent.generate();
    var header_buf: [55]u8 = undefined;
    const header = tp.formatHeader(&header_buf);

    try testing.expectEqual(@as(usize, 55), header.len);
    try testing.expect(std.mem.startsWith(u8, header, "00-"));
    try testing.expect(std.mem.endsWith(u8, header, "-01"));
}

test "Telemetry: Profiler timing and DO_NOT_TRACK compliance" {
    // 1. Profiler
    var profiler = cli.profiler.start();
    profiler.recordParse();
    profiler.recordExec();

    var prof_buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&prof_buf);
    try profiler.render(&writer);
    const prof_out = prof_buf[0 .. prof_buf.len - writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, prof_out, "Execution Profile") != null);
    try testing.expect(std.mem.indexOf(u8, prof_out, "Parse time:") != null);
    try testing.expect(std.mem.indexOf(u8, prof_out, "Exec time:") != null);

    // 2. DO_NOT_TRACK check
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    try testing.expect(!cli.telemetry.isOptedOut(&env_map));
    try env_map.put("DO_NOT_TRACK", "1");
    try testing.expect(cli.telemetry.isOptedOut(&env_map));
}

test "Safeguards: Interactive confirmation safeguard (--yes / -y)" {
    const DestructiveCmd = struct {
        name: []const u8 = "wipe-database",
        description: []const u8 = "Destructive command",
        requires_confirmation: bool = true,
        run: *const fn (ctx: App.Ctx, flags: App.Flags(struct {})) App.Error!void = struct {
            fn run_fn(c: App.Ctx, f: App.Flags(struct {})) App.Error!void {
                _ = c;
                _ = f;
            }
        }.run_fn,
    }{};

    var in_buf: [1]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var dummy: usize = 0;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const non_tty_ctx = App.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = &out,
        .err = &err,
        .state = &dummy,
        .env_map = &env_map,
        .io = std.testing.io,
        .is_tty = false,
    };

    // 1. Without confirmation flag in non-interactive mode: should fail with ConfirmationRequired
    var chain1 = try App.ExecutionChain.init(testing.allocator, 0);
    defer chain1.deinit(testing.allocator);
    var empty_args = [_][]const u8{};
    const res1 = App.execute(DestructiveCmd, non_tty_ctx, &empty_args, &chain1);
    try testing.expectError(error.ConfirmationRequired, res1);

    // 2. With --yes: should succeed
    var chain2 = try App.ExecutionChain.init(testing.allocator, 1);
    defer chain2.deinit(testing.allocator);
    var yes_args = [_][]const u8{"--yes"};
    try App.execute(DestructiveCmd, non_tty_ctx, &yes_args, &chain2);
}

test "Shell completions: bash, fish, and powershell script generation" {
    // 1. Bash
    {
        var out_buf: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&out_buf);
        var err_buf: [1024]u8 = undefined;
        var err = std.Io.Writer.fixed(&err_buf);
        var args = [_][]const u8{ "generate-completions", "bash" };
        try testExecute(&args, &out, &err);
        const result = out_buf[0 .. out_buf.len - out.unusedCapacityLen()];
        try testing.expect(std.mem.indexOf(u8, result, "_mycli_completions()") != null);
        try testing.expect(std.mem.indexOf(u8, result, "complete -F _mycli_completions mycli") != null);
    }

    // 2. Fish
    {
        var out_buf: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&out_buf);
        var err_buf: [1024]u8 = undefined;
        var err = std.Io.Writer.fixed(&err_buf);
        var args = [_][]const u8{ "generate-completions", "fish" };
        try testExecute(&args, &out, &err);
        const result = out_buf[0 .. out_buf.len - out.unusedCapacityLen()];
        try testing.expect(std.mem.indexOf(u8, result, "function __fish_mycli_complete") != null);
        try testing.expect(std.mem.indexOf(u8, result, "complete -c mycli -f -a '(__fish_mycli_complete)'") != null);
    }

    // 3. PowerShell
    {
        var out_buf: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&out_buf);
        var err_buf: [1024]u8 = undefined;
        var err = std.Io.Writer.fixed(&err_buf);
        var args = [_][]const u8{ "generate-completions", "powershell" };
        try testExecute(&args, &out, &err);
        const result = out_buf[0 .. out_buf.len - out.unusedCapacityLen()];
        try testing.expect(std.mem.indexOf(u8, result, "Register-ArgumentCompleter -Native -CommandName mycli") != null);
    }
}

test "Doc generation: markdown and man page" {
    // 1. Markdown
    {
        var out_buf: [2048]u8 = undefined;
        var out = std.Io.Writer.fixed(&out_buf);
        var err_buf: [1024]u8 = undefined;
        var err = std.Io.Writer.fixed(&err_buf);
        var args = [_][]const u8{ "generate-docs", "markdown" };
        try testExecute(&args, &out, &err);
        const result = out_buf[0 .. out_buf.len - out.unusedCapacityLen()];
        try testing.expect(std.mem.indexOf(u8, result, "# mycli") != null);
        try testing.expect(std.mem.indexOf(u8, result, "Root command") != null);
        try testing.expect(std.mem.indexOf(u8, result, "## Subcommands") != null);
        try testing.expect(std.mem.indexOf(u8, result, "**auth**") != null);
    }

    // 2. Man Page
    {
        var out_buf: [2048]u8 = undefined;
        var out = std.Io.Writer.fixed(&out_buf);
        var err_buf: [1024]u8 = undefined;
        var err = std.Io.Writer.fixed(&err_buf);
        var args = [_][]const u8{ "generate-docs", "man" };
        try testExecute(&args, &out, &err);
        const result = out_buf[0 .. out_buf.len - out.unusedCapacityLen()];
        try testing.expect(std.mem.indexOf(u8, result, ".TH mycli 1") != null);
        try testing.expect(std.mem.indexOf(u8, result, ".SH NAME") != null);
        try testing.expect(std.mem.indexOf(u8, result, ".SH SYNOPSIS") != null);
        // The section is COMMANDS, and each subcommand gets its own `.SS` entry rather
        // than only being listed - a man page that stops at depth one hides a nested
        // CLI's whole structure.
        try testing.expect(std.mem.indexOf(u8, result, ".SH COMMANDS") != null);
        try testing.expect(std.mem.indexOf(u8, result, ".SS login") != null);
        // `mycli`'s root declares `--verbose`, so the page has an OPTIONS section.
        try testing.expect(std.mem.indexOf(u8, result, ".SH OPTIONS") != null);
        try testing.expect(std.mem.indexOf(u8, result, ".B --verbose, -v") != null);
    }
}

test "VFS: VirtualFileSystem asset lookup and extraction" {
    const assets = [_]cli.vfs.EmbeddedAsset{
        .{
            .path = "config/defaults.json",
            .content = "{\"theme\": \"dark\"}",
            .mime = "application/json",
        },
        .{
            .path = "banner.txt",
            .content = "Snek v1.0",
            .mime = "text/plain",
        },
    };

    const vfs = cli.vfs.VirtualFileSystem.init(&assets);

    // Lookup
    try testing.expectEqualStrings("{\"theme\": \"dark\"}", vfs.get("config/defaults.json").?);
    try testing.expectEqualStrings("Snek v1.0", vfs.get("banner.txt").?);
    try testing.expect(vfs.get("nonexistent.txt") == null);

    const asset = vfs.getAsset("banner.txt").?;
    try testing.expectEqualStrings("text/plain", asset.mime);

    // Extraction to test directory
    const test_dir = "test_vfs_extract";
    try vfs.extractAll(std.testing.io, test_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};

    const banner_file = try std.Io.Dir.cwd().openFile(std.testing.io, "test_vfs_extract/banner.txt", .{});
    defer banner_file.close(std.testing.io);
    var b_buf: [128]u8 = undefined;
    const b_buffers = [_][]u8{&b_buf};
    const b_read = try banner_file.readStreaming(std.testing.io, &b_buffers);
    try testing.expectEqualStrings("Snek v1.0", b_buf[0..b_read]);

    const json_file = try std.Io.Dir.cwd().openFile(std.testing.io, "test_vfs_extract/config/defaults.json", .{});
    defer json_file.close(std.testing.io);
    var j_buf: [128]u8 = undefined;
    const j_buffers = [_][]u8{&j_buf};
    const j_read = try json_file.readStreaming(std.testing.io, &j_buffers);
    try testing.expectEqualStrings("{\"theme\": \"dark\"}", j_buf[0..j_read]);
}

var task_execution_log: [4][]const u8 = undefined;
var task_execution_idx: usize = 0;

test "TaskRunner: Dependency graph ordering and circular dependency detection" {
    task_execution_idx = 0;

    const task_clean = cli.tasks.Task{
        .name = "clean",
        .description = "Clean build artifacts",
        .run = struct {
            fn run_fn(alloc: std.mem.Allocator) cli.tasks.TaskRunError!void {
                _ = alloc;
                task_execution_log[task_execution_idx] = "clean";
                task_execution_idx += 1;
            }
        }.run_fn,
    };

    const task_codegen = cli.tasks.Task{
        .name = "codegen",
        .description = "Generate code",
        .deps = &[_][]const u8{"clean"},
        .run = struct {
            fn run_fn(alloc: std.mem.Allocator) cli.tasks.TaskRunError!void {
                _ = alloc;
                task_execution_log[task_execution_idx] = "codegen";
                task_execution_idx += 1;
            }
        }.run_fn,
    };

    const task_build = cli.tasks.Task{
        .name = "build",
        .description = "Compile project",
        .deps = &[_][]const u8{"codegen"},
        .run = struct {
            fn run_fn(alloc: std.mem.Allocator) cli.tasks.TaskRunError!void {
                _ = alloc;
                task_execution_log[task_execution_idx] = "build";
                task_execution_idx += 1;
            }
        }.run_fn,
    };

    const all_tasks = [_]cli.tasks.Task{ task_clean, task_codegen, task_build };
    const runner = cli.tasks.TaskRunner.init(testing.allocator, &all_tasks);

    var run_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&run_buf);
    try runner.run("build", &writer);

    try testing.expectEqual(@as(usize, 3), task_execution_idx);
    try testing.expectEqualStrings("clean", task_execution_log[0]);
    try testing.expectEqualStrings("codegen", task_execution_log[1]);
    try testing.expectEqualStrings("build", task_execution_log[2]);

    // Circular dependency detection
    const task_cycle_a = cli.tasks.Task{
        .name = "cycle-a",
        .deps = &[_][]const u8{"cycle-b"},
        .run = struct {
            fn r(a: std.mem.Allocator) cli.tasks.TaskRunError!void {
                _ = a;
            }
        }.r,
    };
    const task_cycle_b = cli.tasks.Task{
        .name = "cycle-b",
        .deps = &[_][]const u8{"cycle-a"},
        .run = struct {
            fn r(a: std.mem.Allocator) cli.tasks.TaskRunError!void {
                _ = a;
            }
        }.r,
    };

    const cycle_tasks = [_]cli.tasks.Task{ task_cycle_a, task_cycle_b };
    const cycle_runner = cli.tasks.TaskRunner.init(testing.allocator, &cycle_tasks);

    var cycle_buf: [1024]u8 = undefined;
    var cycle_writer = std.Io.Writer.fixed(&cycle_buf);
    const err = cycle_runner.run("cycle-a", &cycle_writer);
    try testing.expectError(error.CircularDependency, err);
}

test "Daemon: PidFile creation, duplicate detection, and cleanup" {
    const pid_file_path = "test_daemon.pid";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, pid_file_path) catch {};

    // 1. Initial lock
    var pid_lock = try cli.daemon.PidFile.init(testing.allocator, std.testing.io, pid_file_path);

    // 2. Duplicate init on the same running PID should return ProcessAlreadyRunning
    const dup_res = cli.daemon.PidFile.init(testing.allocator, std.testing.io, pid_file_path);
    try testing.expectError(error.ProcessAlreadyRunning, dup_res);

    // 3. Deinit should release and delete the file
    pid_lock.deinit();

    // 4. File should be removed, so another init succeeds
    var pid_lock2 = try cli.daemon.PidFile.init(testing.allocator, std.testing.io, pid_file_path);
    pid_lock2.deinit();
}

test "Cancellation: Atomic token state and cancellation control" {
    var cancel = cli.cancellation.init();
    try testing.expect(!cancel.isCancelled());
    cancel.cancel();
    try testing.expect(cancel.isCancelled());
    cancel.reset();
    try testing.expect(!cancel.isCancelled());
}

test "Alias: Git-style alias parsing and argument resolution" {
    var alias_map = cli.alias.AliasMap.init(testing.allocator);
    defer alias_map.deinit();

    const config_text =
        \\# Sample alias config
        \\[alias]
        \\st = status --short
        \\ci = commit -m
        \\br = branch
    ;
    try alias_map.parseFromContent(config_text);

    try testing.expectEqualStrings("status --short", alias_map.get("st").?);
    try testing.expectEqualStrings("commit -m", alias_map.get("ci").?);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Resolving 'st' -> ['status', '--short']
    const args1 = [_][]const u8{"st"};
    const resolved1 = try alias_map.resolve(arena.allocator(), &args1);
    try testing.expectEqual(@as(usize, 2), resolved1.len);
    try testing.expectEqualStrings("status", resolved1[0]);
    try testing.expectEqualStrings("--short", resolved1[1]);

    // Resolving 'ci' with extra arg "Initial commit" -> ['commit', '-m', 'Initial commit']
    const args2 = [_][]const u8{ "ci", "Initial commit" };
    const resolved2 = try alias_map.resolve(arena.allocator(), &args2);
    try testing.expectEqual(@as(usize, 3), resolved2.len);
    try testing.expectEqualStrings("commit", resolved2[0]);
    try testing.expectEqualStrings("-m", resolved2[1]);
    try testing.expectEqualStrings("Initial commit", resolved2[2]);
}

test "Config: JSON merge and ProfileManager" {
    const ServerConfig = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8080,
        debug: bool = false,
    };

    var cfg = ServerConfig{};
    const json_data = "{\"port\": 9000, \"debug\": true}";
    try cli.cfg.mergeJson(&cfg, json_data, testing.allocator);

    try testing.expectEqualStrings("127.0.0.1", cfg.host);
    try testing.expectEqual(@as(u16, 9000), cfg.port);
    try testing.expect(cfg.debug);

    // ProfileManager
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const pm = cli.cfg.ProfileManager.init(".mycli", null, &env_map);
    try testing.expectEqualStrings("default", pm.active_profile);

    var path_buf: [128]u8 = undefined;
    const profile_path = try pm.getProfilePath(&path_buf);
    try testing.expectEqualStrings(".mycli/profiles/default.json", profile_path);

    const pm_custom = cli.cfg.ProfileManager.init(".mycli", "staging", &env_map);
    const custom_path = try pm_custom.getProfilePath(&path_buf);
    try testing.expectEqualStrings(".mycli/profiles/staging.json", custom_path);
}

test "OAuth: RFC 8628 Device Authorization flow" {
    const auth_resp = cli.oauth.DeviceAuthResponse{
        .device_code = "d_123456",
        .user_code = "WDJB-MJHT",
        .verification_uri = "https://example.com/device",
        .verification_uri_complete = "https://example.com/device?code=WDJB-MJHT",
    };

    var prompt_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&prompt_buf);
    try cli.oauth.OAuthDeviceFlow.renderPrompt(&writer, auth_resp);
    const out = prompt_buf[0 .. prompt_buf.len - writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, out, "WDJB-MJHT") != null);
    try testing.expect(std.mem.indexOf(u8, out, "https://example.com/device") != null);

    // Token poll response: pending
    const poll_pending = try cli.oauth.OAuthDeviceFlow.parseTokenPollResponse(400, "{\"error\": \"authorization_pending\"}", testing.allocator);
    try testing.expectEqual(cli.oauth.PollStatus.pending, poll_pending.poll);

    // Token poll response: success
    var poll_success = try cli.oauth.OAuthDeviceFlow.parseTokenPollResponse(200, "{\"access_token\": \"gho_secret123\", \"token_type\": \"Bearer\"}", testing.allocator);
    defer poll_success.deinit();
    try testing.expectEqualStrings("gho_secret123", poll_success.success.value.access_token);
}

test "Layout: Split-pane horizontal and vertical rendering" {
    const left = "Line 1\nLine 2";
    const right = "Right A\nRight B";

    var h_buf: [1024]u8 = undefined;
    var h_writer = std.Io.Writer.fixed(&h_buf);
    try cli.layout.split(&h_writer, left, right, .{ .direction = .horizontal, .divider = "│" });
    const h_out = h_buf[0 .. h_buf.len - h_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, h_out, "Line 1 │ Right A") != null);
    try testing.expect(std.mem.indexOf(u8, h_out, "Line 2 │ Right B") != null);

    var v_buf: [1024]u8 = undefined;
    var v_writer = std.Io.Writer.fixed(&v_buf);
    try cli.layout.split(&v_writer, "Top Block", "Bottom Block", .{ .direction = .vertical, .divider = "---" });
    const v_out = v_buf[0 .. v_buf.len - v_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, v_out, "Top Block\n---\nBottom Block") != null);
}

test "Logging: Dynamic log level extraction from arguments" {
    const args1 = [_][]const u8{ "server", "start", "--log-level=debug" };
    try testing.expectEqual(@as(?std.log.Level, .debug), cli.extractLogLevel(&args1));

    const args2 = [_][]const u8{ "server", "start", "--log-level", "warn" };
    try testing.expectEqual(@as(?std.log.Level, .warn), cli.extractLogLevel(&args2));

    const args3 = [_][]const u8{ "server", "start" };
    try testing.expectEqual(@as(?std.log.Level, null), cli.extractLogLevel(&args3));
}

test "TUI: SGR ANSI mouse event parsing" {
    // Left click at (15, 8): \x1b[<0;15;8M
    const mouse_click = cli.tea.parseMouse("\x1b[<0;15;8M").?;
    try testing.expectEqual(cli.tea.MouseButton.left, mouse_click.button);
    try testing.expectEqual(@as(u16, 15), mouse_click.x);
    try testing.expectEqual(@as(u16, 8), mouse_click.y);

    // Release at (15, 8): \x1b[<0;15;8m
    const mouse_release = cli.tea.parseMouse("\x1b[<0;15;8m").?;
    try testing.expectEqual(cli.tea.MouseButton.release, mouse_release.button);

    // Wheel up at (20, 5): \x1b[<64;20;5M
    const mouse_wheel = cli.tea.parseMouse("\x1b[<64;20;5M").?;
    try testing.expectEqual(cli.tea.MouseButton.wheel_up, mouse_wheel.button);
}

test "TUI: VirtualList viewport scrolling" {
    var vlist = cli.tea.VirtualList.init(100, 10);
    try testing.expectEqual(@as(usize, 0), vlist.cursor);
    try testing.expectEqual(@as(usize, 0), vlist.offset);

    // Scroll down 5 times
    for (0..5) |_| vlist.scrollDown();
    try testing.expectEqual(@as(usize, 5), vlist.cursor);
    try testing.expectEqual(@as(usize, 0), vlist.offset);

    // Scroll past viewport height
    for (0..10) |_| vlist.scrollDown();
    try testing.expectEqual(@as(usize, 15), vlist.cursor);
    try testing.expect(vlist.offset > 0);

    const range = vlist.visibleRange();
    try testing.expectEqual(vlist.offset, range.start);
    try testing.expectEqual(vlist.offset + 10, range.end);
}

test "Color: Truecolor degradation to ANSI 16 and 256 colors" {
    const red = cli.color.RGB{ .r = 255, .g = 0, .b = 0 };
    // Downsamples to 9 (Bright Red) in ANSI 16
    try testing.expectEqual(@as(u8, 9), red.toAnsi16());

    const green = cli.color.RGB{ .r = 0, .g = 255, .b = 0 };
    try testing.expectEqual(@as(u8, 10), green.toAnsi16());

    // Formatting ANSI escape codes
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try cli.color.ColorEngine.formatFg(&writer, red, .ansi16);
    const out = buf[0 .. buf.len - writer.unusedCapacityLen()];
    try testing.expectEqualStrings("\x1b[91m", out);
}

test "Graphics: Terminal protocol detection and inline image formatting" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    // Kitty detection
    try env_map.put("KITTY_WINDOW_ID", "1");
    try testing.expectEqual(cli.graphics.GraphicsProtocol.kitty, cli.graphics.TerminalGraphics.detectProtocol(&env_map));

    // Kitty image rendering
    var out_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    const fake_img = "test_image_data";
    try cli.graphics.TerminalGraphics.renderInlineImage(&writer, fake_img, .kitty, testing.allocator);
    const rendered = out_buf[0 .. out_buf.len - writer.unusedCapacityLen()];
    try testing.expect(std.mem.startsWith(u8, rendered, "\x1b_Ga=T,f=100,m=0;"));
    try testing.expect(std.mem.endsWith(u8, rendered, "\x1b\\"));
}

test "Updater: Atomic binary swap and rollback preservation" {
    const test_exe = "test_binary.bin";
    const test_old = "test_binary.bin.old";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, test_exe) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, test_old) catch {};

    // Create original dummy binary
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, test_exe, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writePositionalAll(std.testing.io, "v1.0.0", 0);
    }

    // Run self-update with v2.0.0
    try cli.updater.SelfUpdater.updateBinary(std.testing.io, test_exe, "v2.0.0");

    // Read new exe
    const f_new = try std.Io.Dir.cwd().openFile(std.testing.io, test_exe, .{});
    defer f_new.close(std.testing.io);
    var buf_new: [16]u8 = undefined;
    const bufs_new = [_][]u8{&buf_new};
    const read_new = try f_new.readStreaming(std.testing.io, &bufs_new);
    try testing.expectEqualStrings("v2.0.0", buf_new[0..read_new]);

    // Read backup .old
    const f_old = try std.Io.Dir.cwd().openFile(std.testing.io, test_old, .{});
    defer f_old.close(std.testing.io);
    var buf_old: [16]u8 = undefined;
    const bufs_old = [_][]u8{&buf_old};
    const read_old = try f_old.readStreaming(std.testing.io, &bufs_old);
    try testing.expectEqualStrings("v1.0.0", buf_old[0..read_old]);
}

test "Headless: Terminal buffer recording and golden assertions" {
    var ht = cli.headless.HeadlessTerminal.init(testing.allocator);
    defer ht.deinit();

    var writer = ht.writer();
    try writer.writeAll("Expected Golden Output\n");

    try ht.assertGolden("Expected Golden Output");
}

test "REPL: Stateful history tracking and prefix autocomplete" {
    var repl = cli.repl.ReplState.init(testing.allocator);
    defer repl.deinit();

    try repl.addHistory("status");
    try repl.addHistory("cluster join");
    try testing.expectEqual(@as(usize, 2), repl.history.items.len);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const candidates = [_][]const u8{ "status", "start", "stop", "config", "cluster" };
    const comps = try repl.getCompletions("st", &candidates, arena.allocator());
    try testing.expectEqual(@as(usize, 3), comps.len);
    try testing.expectEqualStrings("status", comps[0]);
    try testing.expectEqualStrings("start", comps[1]);
    try testing.expectEqualStrings("stop", comps[2]);
}

test "Security: Automated Secret Management with formatFlags redaction" {
    const Credentials = struct {
        username: []const u8 = "alice",
        token: []const u8 = "supersecrettoken123",
        pin: u32 = 1234,

        pub const meta = .{
            .token = .{ .secret = true },
            .pin = .{ .secret = true },
        };
    };

    const creds = Credentials{};
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try cli.formatFlags(&writer, creds);
    const out = buf[0 .. buf.len - writer.unusedCapacityLen()];

    try testing.expect(std.mem.indexOf(u8, out, "username: alice") != null);
    try testing.expect(std.mem.indexOf(u8, out, "supersecrettoken123") == null);
    try testing.expect(std.mem.indexOf(u8, out, "s*****************3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pin: ********") != null);
}

test "VTE: Synchronized Output Protocol emission" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try cli.vte.beginSync(&writer);
    try writer.writeAll("RENDER_CONTENT");
    try cli.vte.endSync(&writer);
    const out = buf[0 .. buf.len - writer.unusedCapacityLen()];
    try testing.expectEqualStrings("\x1b[?2026hRENDER_CONTENT\x1b[?2026l", out);
}

test "VTE: Native OS taskbar progress reporting" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try cli.vte.writeTaskbarProgress(&writer, .normal, 75);
    const out1 = buf[0 .. buf.len - writer.unusedCapacityLen()];
    try testing.expectEqualStrings("\x1b]9;4;1;75\x1b\\", out1);

    writer = std.Io.Writer.fixed(&buf);
    try cli.vte.writeTaskbarProgress(&writer, .error_state, 100);
    const out2 = buf[0 .. buf.len - writer.unusedCapacityLen()];
    try testing.expectEqualStrings("\x1b]9;4;2;100\x1b\\", out2);
}

test "VTE: Adaptive dynamic palette query RGB parsing" {
    // Dark theme RGB response
    const dark_resp = "\x1b]11;rgb:1010/2020/3030\x1b\\";
    const dark_parsed = cli.vte.parseRgbResponse(dark_resp).?;
    try testing.expectEqual(@as(u8, 0x10), dark_parsed.r);
    try testing.expectEqual(@as(u8, 0x20), dark_parsed.g);
    try testing.expectEqual(@as(u8, 0x30), dark_parsed.b);
    try testing.expectEqual(cli.vte.PaletteTheme.dark, dark_parsed.theme);

    // Light theme RGB response
    const light_resp = "\x1b]11;rgb:ffff/eeee/dddd\x1b\\";
    const light_parsed = cli.vte.parseRgbResponse(light_resp).?;
    try testing.expectEqual(@as(u8, 0xff), light_parsed.r);
    try testing.expectEqual(cli.vte.PaletteTheme.light, light_parsed.theme);
}

test "VTE: Bracketed paste guard detection and extraction" {
    const raw_paste = "\x1b[200~echo hello\nrm -rf /\x1b[201~";
    try testing.expect(cli.vte.isPastedInput(raw_paste));

    const content = cli.vte.extractPastedContent(raw_paste).?;
    try testing.expectEqualStrings("echo hello\nrm -rf /", content);

    const normal_input = "ls -la";
    try testing.expect(!cli.vte.isPastedInput(normal_input));
    try testing.expect(cli.vte.extractPastedContent(normal_input) == null);
}

test "OS Primitives: MmapFile zero-copy reading" {
    const test_path = "test_mmap_file.dat";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};

    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, test_path, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writePositionalAll(std.testing.io, "Zero-Copy Memory-Mapped Argument Payload", 0);
    }

    var mmap_f = try cli.mmap.MmapFile.open(test_path);
    defer mmap_f.deinit();

    try testing.expectEqualStrings("Zero-Copy Memory-Mapped Argument Payload", mmap_f.bytes);
    try testing.expectEqual(@as(usize, 40), mmap_f.size);
}

test "OS Primitives: Terminal crash supervisor and sane sequence" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try cli.supervisor.TerminalSupervisor.restoreTerminalSanity(&writer);
    const out = buf[0 .. buf.len - writer.unusedCapacityLen()];
    try testing.expectEqualStrings("\x1b[0m\x1b[?25h\x1b[!p", out);
}

test "OS Primitives: Ephemeral kernel sandbox path validation" {
    const policy = cli.sandbox.SandboxPolicy{
        .read_paths = &[_][]const u8{ "/tmp", "./data" },
        .write_paths = &[_][]const u8{"./data/output"},
        .allow_network = false,
    };
    const sb = cli.sandbox.init(policy);

    // Read checks
    try testing.expect(sb.isPathAllowed("/tmp/test.txt", false));
    try testing.expect(sb.isPathAllowed("./data/input.json", false));
    try testing.expect(!sb.isPathAllowed("/etc/passwd", false));

    // Write checks
    try testing.expect(sb.isPathAllowed("./data/output/res.csv", true));
    try testing.expect(!sb.isPathAllowed("./data/input.json", true));
}

test "OS Primitives: In-memory process title and argument secret scrubbing" {
    var secret_buf = [_]u8{ 's', 'e', 'c', 'r', 'e', 't', '_', 't', 'o', 'k', 'e', 'n' };
    cli.proctitle.ProcessTitle.scrubSecretArg(&secret_buf);
    for (secret_buf) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }

    cli.proctitle.ProcessTitle.setTitle("snek [running]");
}

test "Comptime Safety: Static flag collision linter" {
    const SafeFlags = struct {
        port: u16 = 8080,
        verbose: bool = false,
        pub const meta = .{
            .port = .{ .short = 'p' },
            .verbose = .{ .short = 'v' },
        };
    };
    cli.linter.ComptimeLinter.lintFlags(SafeFlags);
}

test "Comptime: WebAssembly playground string-buffer bridge" {
    // `wasm_bridge` is a file-as-type module: the import IS the struct, so this
    // is `<module>{}` rather than `<module>.WasmBridge{}`. See `.agents/AGENTS.md`.
    var bridge = cli.wasm_bridge{};
    const dummy_exec = struct {
        fn run(argv: []const []const u8, writer: *std.Io.Writer) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
            try writer.print("Args received: {d}\n", .{argv.len});
        }
    }.run;

    const res = try bridge.executeString("app run --verbose", dummy_exec, testing.allocator);
    try testing.expectEqualStrings("Args received: 3\n", res);
}

test "DAG: Topological command dependency graph execution stages" {
    const nodes = [_]cli.dag.DagNode{
        .{ .name = "lint" },
        .{ .name = "codegen" },
        .{ .name = "compile", .deps = &[_][]const u8{ "lint", "codegen" } },
        .{ .name = "package", .deps = &[_][]const u8{"compile"} },
    };

    const pipeline = cli.dag.DagPipeline.init(&nodes);
    const stages = try pipeline.computeStages(testing.allocator);
    defer cli.dag.DagPipeline.freeStages(stages, testing.allocator);

    try testing.expectEqual(@as(usize, 3), stages.len);
    // Stage 0: lint, codegen
    try testing.expectEqual(@as(usize, 2), stages[0].len);
    // Stage 1: compile
    try testing.expectEqual(@as(usize, 1), stages[1].len);
    try testing.expectEqualStrings("compile", stages[1][0]);
    // Stage 2: package
    try testing.expectEqual(@as(usize, 1), stages[2].len);
    try testing.expectEqualStrings("package", stages[2][0]);

    // Cycle detection
    const cycle_nodes = [_]cli.dag.DagNode{
        .{ .name = "a", .deps = &[_][]const u8{"b"} },
        .{ .name = "b", .deps = &[_][]const u8{"a"} },
    };
    const cycle_pipeline = cli.dag.DagPipeline.init(&cycle_nodes);
    try testing.expectError(error.CircularDependency, cycle_pipeline.computeStages(testing.allocator));
}

test "OpenAPI: Comptime REST gateway JSON generation" {
    const MockCmd = struct {
        pub const name = "cluster";
        pub const description = "Cluster management API";
        pub const subcommands = [_]struct {
            name: []const u8,
            description: []const u8,
        }{
            .{ .name = "create", .description = "Create new cluster" },
            .{ .name = "destroy", .description = "Destroy existing cluster" },
        };
    };

    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try cli.openapi.OpenApiGenerator.generateJson(&writer, MockCmd);
    const out = buf[0 .. buf.len - writer.unusedCapacityLen()];

    try testing.expect(std.mem.indexOf(u8, out, "\"openapi\": \"3.0.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"/create\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"/destroy\":") != null);
}

test "TUI Pro: DECSTBM split scrolling regions" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try cli.decstbm.setScrollRegion(&writer, 1, 20);
    const out1 = buf[0 .. buf.len - writer.unusedCapacityLen()];
    try testing.expectEqualStrings("\x1b[1;20r", out1);

    writer = std.Io.Writer.fixed(&buf);
    try cli.decstbm.resetScrollRegion(&writer);
    const out2 = buf[0 .. buf.len - writer.unusedCapacityLen()];
    try testing.expectEqualStrings("\x1b[r", out2);
}

test "TUI Pro: VirtualTerminal 2D cell grid and SVG snapshot export" {
    var vt = try cli.virtual_terminal.init(testing.allocator, 10, 5);
    defer vt.deinit();

    vt.writeString(0, 0, "HELLO");
    var line_buf: [10]u8 = undefined;
    const line = vt.getLine(0, &line_buf);
    try testing.expectEqualStrings("HELLO     ", line);

    var svg_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&svg_buf);
    try vt.exportSvg(&writer);
    const svg_out = svg_buf[0 .. svg_buf.len - writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, svg_out, "<svg xmlns=\"http://www.w3.org/2000/svg\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg_out, "HELLO") != null);
}

test "TUI Pro: Unified Spatial Focus Grid navigation" {
    var grid = cli.spatial_focus.SpatialFocusGrid.init(3, 2, true); // 3 rows, 2 cols
    try testing.expectEqual(@as(usize, 0), grid.getIndex());

    _ = grid.moveRight();
    try testing.expectEqual(@as(usize, 1), grid.getIndex());

    _ = grid.moveRight(); // Wraps to next row, col 0
    try testing.expectEqual(@as(usize, 2), grid.getIndex());

    _ = grid.moveDown();
    try testing.expectEqual(@as(usize, 4), grid.getIndex());

    _ = grid.moveDown(); // Wraps to top row
    try testing.expectEqual(@as(usize, 0), grid.getIndex());
}

test "TUI Pro: RopeBuffer multi-line text editing" {
    var rope = cli.rope.RopeBuffer.init(testing.allocator);
    defer rope.deinit();

    try rope.appendLine("First Line");
    try rope.appendLine("Third Line");
    try rope.insertLine(1, "Second Line");

    try testing.expectEqual(@as(usize, 3), rope.lineCount());
    try testing.expectEqualStrings("First Line", rope.getLine(0).?);
    try testing.expectEqualStrings("Second Line", rope.getLine(1).?);
    try testing.expectEqualStrings("Third Line", rope.getLine(2).?);

    rope.deleteLine(1);
    try testing.expectEqual(@as(usize, 2), rope.lineCount());
    try testing.expectEqualStrings("Third Line", rope.getLine(1).?);
}

test "Caching & State: Content-Addressable Result Caching (CAS)" {
    const key = cli.cas.CasStore.computeKey("deploy", "--prod --region=us-east");
    var hex_buf: [64]u8 = undefined;
    const hex = cli.cas.CasStore.formatKeyHex(key, &hex_buf);
    try testing.expectEqual(@as(usize, 64), hex.len);

    // Deterministic: same inputs give identical hex
    const key2 = cli.cas.CasStore.computeKey("deploy", "--prod --region=us-east");
    var hex_buf2: [64]u8 = undefined;
    const hex2 = cli.cas.CasStore.formatKeyHex(key2, &hex_buf2);
    try testing.expectEqualStrings(hex, hex2);
}

test "Caching & State: Transactional WorkspaceStore" {
    var store = cli.btree_store.WorkspaceStore.init(testing.allocator);
    defer store.deinit();

    try store.put("auth.token", "gho_abcdef123");
    try store.put("env", "staging");

    try testing.expectEqualStrings("gho_abcdef123", store.get("auth.token").?);
    try testing.expectEqualStrings("staging", store.get("env").?);
    try testing.expect(store.get("nonexistent") == null);

    store.delete("env");
    try testing.expect(store.get("env") == null);
}

test "Data Flow: Structured Object Piping (TTY vs NDJSON)" {
    const Record = struct {
        id: u32,
        name: []const u8,
    };
    const rec = Record{ .id = 42, .name = "Alice" };

    // NDJSON streaming format
    var json_buf: [256]u8 = undefined;
    var json_writer = std.Io.Writer.fixed(&json_buf);
    try cli.object_pipe.pipeRecord(&json_writer, rec, false);
    const json_out = json_buf[0 .. json_buf.len - json_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, json_out, "{\"id\":42,\"name\":\"Alice\"}") != null);

    // TTY human readable
    var tty_buf: [256]u8 = undefined;
    var tty_writer = std.Io.Writer.fixed(&tty_buf);
    try cli.object_pipe.pipeRecord(&tty_writer, rec, true);
    const tty_out = tty_buf[0 .. tty_buf.len - tty_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, tty_out, "Alice") != null);
}

test "Data Flow: DryRunLedger mutation tracking and diff rendering" {
    var ledger = cli.dry_run.DryRunLedger.init(testing.allocator);
    defer ledger.deinit();

    try ledger.record(.create_file, "/etc/snek.conf", "size: 1KB");
    try ledger.record(.delete_file, "/tmp/legacy.db", "");

    var diff_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&diff_buf);
    // The colour decision is the caller's, and a test is a stream that is not a terminal,
    // so this is the no-escapes render.
    try ledger.renderDiff(&writer, false);
    const out = diff_buf[0 .. diff_buf.len - writer.unusedCapacityLen()];

    try testing.expect(std.mem.indexOf(u8, out, "=== DRY RUN: Proposed Mutations ===") != null);
    // The property the parameter exists for: a ledger piped into a file or through `grep`
    // must not carry escape codes.
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x1b) == null);
    try testing.expect(std.mem.indexOf(u8, out, "[+CREATE]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/etc/snek.conf") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[-DELETE]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/tmp/legacy.db") != null);
}

test "Security & Governance: Pre-Execution Policy-as-Code Engine" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    try env_map.put("ENVIRONMENT", "production");

    const rules = [_]cli.policy.PolicyRule{
        .{
            .name = "protect_prod",
            .forbidden_env = "ENVIRONMENT",
            .required_flag = "--force-with-lease",
            .message = "Production actions require --force-with-lease",
        },
    };

    var err_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&err_buf);

    // Without required flag: violation
    const flags_missing = [_][]const u8{"--cluster=us-east"};
    const res = cli.policy.PolicyEngine.evaluate(&rules, &env_map, &flags_missing, &writer);
    try testing.expectError(error.PolicyViolation, res);

    // With required flag: success
    writer = std.Io.Writer.fixed(&err_buf);
    const flags_ok = [_][]const u8{ "--cluster=us-east", "--force-with-lease" };
    try cli.policy.PolicyEngine.evaluate(&rules, &env_map, &flags_ok, &writer);
}

test "Security: SecurePage locked heap allocation and wiping" {
    var page = try cli.secure_heap.SecurePage.init(testing.allocator, 128);
    defer page.deinit();

    @memcpy(page.memory[0..6], "secret");
    try testing.expectEqualStrings("secret", page.memory[0..6]);
}

test "Tooling: Multi-platform distribution spec generator" {
    const pkg = cli.dist_specs.PackageMetadata{
        .name = "snek",
        .version = "1.0.0",
        .description = "Next-generation CLI & TUI framework",
        .homepage = "https://snek.dev",
        .author = "Snek Team",
        .url = "https://github.com/93ams/snek/releases/download/v1.0.0/snek.tar.gz",
        .sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    };

    // Homebrew
    var brew_buf: [1024]u8 = undefined;
    var brew_writer = std.Io.Writer.fixed(&brew_buf);
    try cli.dist_specs.DistSpecGenerator.generateHomebrew(&brew_writer, pkg);
    const brew_out = brew_buf[0 .. brew_buf.len - brew_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, brew_out, "class snek < Formula") != null);

    // Scoop
    var scoop_buf: [1024]u8 = undefined;
    var scoop_writer = std.Io.Writer.fixed(&scoop_buf);
    try cli.dist_specs.DistSpecGenerator.generateScoop(&scoop_writer, pkg);
    const scoop_out = scoop_buf[0 .. scoop_buf.len - scoop_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, scoop_out, "\"bin\": \"snek.exe\"") != null);

    // Arch Linux
    var arch_buf: [1024]u8 = undefined;
    var arch_writer = std.Io.Writer.fixed(&arch_buf);
    try cli.dist_specs.DistSpecGenerator.generateArchPkgbuild(&arch_writer, pkg);
    const arch_out = arch_buf[0 .. arch_buf.len - arch_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, arch_out, "pkgname=snek") != null);
}

test "Tooling: FootprintAnalyzer struct metrics" {
    const Dummy = struct {
        id: u64,
        flag: bool,
    };
    const footprint = cli.footprint.FootprintAnalyzer.analyze(Dummy);
    try testing.expect(footprint.size > 0);
    try testing.expectEqual(@as(usize, 2), footprint.field_count);
}

test "Remote Config: Local ETag cache persistence and retrieval" {
    const mgr = cli.remote_config.RemoteConfigManager.init(testing.allocator);
    const cache_path = "test_remote_cache.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cache_path) catch {};

    try mgr.writeCache(std.testing.io, cache_path, "W/\"123456\"", "{\"network\":{\"port\":8080}}");

    var state = mgr.readCache(std.testing.io, cache_path).?;
    defer mgr.freeState(&state);

    try testing.expectEqualStrings("W/\"123456\"", state.etag);
    try testing.expectEqualStrings("{\"network\":{\"port\":8080}}", state.payload);
}

test "OTA Flags: Dynamic feature flag evaluation and command interception" {
    var ota = cli.ota_flags.OtaFlagRegistry.init(testing.allocator);
    defer ota.deinit();

    try ota.loadFromJson("{\"beta_deploy\": false, \"fast_routing\": true}");

    try testing.expect(!ota.isEnabled("beta_deploy"));
    try testing.expect(ota.isEnabled("fast_routing"));
    try testing.expect(ota.isEnabled("unspecified_feature")); // Default true

    try ota.assertAllowed("fast_routing");
    try testing.expectError(error.FeatureDisabled, ota.assertAllowed("beta_deploy"));
    try ota.assertAllowed(null);
}

test "Config Lineage: Provenance tracking and blame inspection" {
    var lineage = cli.config_lineage.init(testing.allocator);
    defer lineage.deinit();

    try lineage.record("network.port", .env, "MYAPP_NETWORK_PORT");
    try lineage.record("database.url", .file, "config.toml");

    const prov = lineage.getProvenance("network.port").?;
    try testing.expectEqual(cli.config_lineage.ConfigSource.env, prov.source);
    try testing.expectEqualStrings("MYAPP_NETWORK_PORT", prov.origin);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try lineage.inspect(&writer, "network.port", "8080", "u16");
    const out = buf[0 .. buf.len - writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, out, "Value: 8080 | Type: u16 | Source: ENV (MYAPP_NETWORK_PORT)") != null);
}

test "Profiles: Multi-tenant contexts and atomic TOML switching" {
    const initial_toml =
        \\# Root configuration
        \\current_context = "development"
        \\
        \\[contexts.development]
        \\port = 8080
        \\
        \\[contexts.production]
        \\port = 443
    ;

    try testing.expectEqualStrings("development", cli.profiles.ContextManager.getCurrentContext(initial_toml).?);

    const switched = try cli.profiles.ContextManager.switchContextContent(testing.allocator, initial_toml, "production");
    defer testing.allocator.free(switched);

    try testing.expectEqualStrings("production", cli.profiles.ContextManager.getCurrentContext(switched).?);
    try testing.expect(std.mem.indexOf(u8, switched, "current_context = \"production\"") != null);
}

test "Config Diff: Comptime visual diffing against default values" {
    const ServerConfig = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8080,
        debug: bool = false,
    };

    const def_cfg = ServerConfig{};
    const active_cfg = ServerConfig{
        .port = 9000,
        .debug = true,
    };

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const diff_count = try cli.config_diff.ConfigDiffer.renderDiff(&writer, def_cfg, active_cfg, false);
    const out = buf[0 .. buf.len - writer.unusedCapacityLen()];

    try testing.expectEqual(@as(usize, 2), diff_count);
    try testing.expect(std.mem.indexOf(u8, out, "- port = 8080") != null);
    try testing.expect(std.mem.indexOf(u8, out, "+ port = 9000") != null);
    try testing.expect(std.mem.indexOf(u8, out, "+ debug = true") != null);
}

test "Schema Migration: Automated sequential version upgrading" {
    const v1_toml =
        \\version = 1
        \\server_port = 8080
    ;

    const migration_v1_v2 = cli.schema_migration.Migration{
        .from_version = 1,
        .to_version = 2,
        .migrate_fn = struct {
            fn run(allocator: std.mem.Allocator, input: []const u8) anyerror![]const u8 {
                _ = input;
                return try allocator.dupe(u8, "version = 2\nnetwork.port = 8080\n");
            }
        }.run,
    };

    const migrations = [_]cli.schema_migration.Migration{migration_v1_v2};
    const upgraded = try cli.schema_migration.SchemaMigrator.migrate(testing.allocator, 2, &migrations, v1_toml);
    defer testing.allocator.free(upgraded);

    try testing.expectEqual(@as(u32, 2), cli.schema_migration.SchemaMigrator.extractVersion(upgraded));
    try testing.expect(std.mem.indexOf(u8, upgraded, "network.port = 8080") != null);
}

test "Comptime Config: Programmable config extraction" {
    const script_content =
        \\// User programmable config
        \\/* JSON_START
        \\{"env": "local", "timeout": 30}
        \\JSON_END */
    ;

    const test_cfg_path = "test_config_script.zig";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, test_cfg_path) catch {};

    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, test_cfg_path, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writePositionalAll(std.testing.io, script_content, 0);
    }

    const json = try cli.comptime_config.ComptimeConfigRunner.readScriptOrCachedJson(
        testing.allocator,
        std.testing.io,
        test_cfg_path,
        "{}",
    );
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"env\": \"local\"") != null);
}

test "Encrypted Config: Zero-knowledge encryption at rest with XChaCha20-Poly1305" {
    const plaintext = "DB_SECRET_PASSWORD=SuperSecret123!456";
    const passphrase = "correct-horse-battery-staple";
    var nonce: [cli.encrypted_config.nonce_length]u8 = undefined;
    @memset(&nonce, 0x42);

    // `encryptWithSalt` rather than `encrypt`: the latter draws a salt through
    // `std.Io.random`, and a test has no `std.Io`. Supplying the salt explicitly keeps
    // the AEAD and the KDF under test while removing the one dependency the test cannot
    // honestly provide. `encrypt`'s own salt generation is covered by
    // `secrets.encrypted_config`'s tests.
    var test_salt: [cli.encrypted_config.salt_length]u8 = undefined;
    @memset(&test_salt, 0x24);
    const encrypted = try cli.encrypted_config.encryptWithSalt(
        testing.allocator,
        plaintext,
        passphrase,
        test_salt,
        nonce,
    );
    defer testing.allocator.free(encrypted);

    // Decrypt with correct passphrase
    const decrypted = try cli.encrypted_config.decrypt(
        testing.allocator,
        encrypted,
        passphrase,
    );
    defer {
        cli.encrypted_config.wipePlaintext(decrypted);
        testing.allocator.free(decrypted);
    }

    try testing.expectEqualStrings(plaintext, decrypted);

    // Decrypt with wrong passphrase should fail authentication
    const bad_dec = cli.encrypted_config.decrypt(
        testing.allocator,
        encrypted,
        "wrong-passphrase",
    );
    try testing.expectError(error.AuthenticationFailed, bad_dec);
}

test "Security: Ephemeral in-memory Secret(T) lifecycle" {
    var secret = try cli.secret_val.Secret([]const u8).init(testing.allocator, "topsecret_token");
    defer secret.deinit();

    // `expose()`/`Exposed` was removed: the guard was copyable while owning destruction,
    // so a copy became a dangling view over a freed buffer. Reading now borrows, which
    // leaves nothing to duplicate.
    try testing.expectEqualStrings("topsecret_token", secret.value());
    try testing.expectEqualStrings("topsecret_token", secret.bytes());

    // `wipe` zeroes the contents without ending the lifetime, so the borrow then reads
    // zeroes rather than freed memory - the property the old guard was meant to give.
    secret.wipe();
    for (secret.bytes()) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "TOML Mutator: Comment-preserving config set mutation" {
    const toml_input =
        \\# Global settings
        \\port = 8080  # Default server port
        \\debug = false
    ;

    const mutated = try cli.toml_mutator.setValue(testing.allocator, toml_input, "port", "9090");
    defer testing.allocator.free(mutated);

    try testing.expect(std.mem.indexOf(u8, mutated, "port = 9090  # Default server port") != null);
    try testing.expect(std.mem.indexOf(u8, mutated, "debug = false") != null);
    try testing.expect(std.mem.indexOf(u8, mutated, "# Global settings") != null);
}

test "Config DryRun: Override parsing and validation matrix rendering" {
    const parsed = cli.config_dryrun.parseOverride("network.port=8080").?;
    try testing.expectEqualStrings("network.port", parsed.key);
    try testing.expectEqualStrings("8080", parsed.value);

    const results = [_]cli.config_dryrun.ValidationResult{
        .{ .key = "network.port", .value = "8080", .is_valid = true },
        .{ .key = "network.tls", .value = "invalid_cert", .is_valid = false, .error_msg = "File not found" },
    };

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try cli.config_dryrun.renderMatrix(&writer, &results);
    const out = buf[0 .. buf.len - writer.unusedCapacityLen()];

    try testing.expect(std.mem.indexOf(u8, out, "[PASS]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "network.port = 8080") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[FAIL]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "network.tls = invalid_cert -> File not found") != null);
}

test "Systemd Exporter: Dot-env and Systemd unit export" {
    const vars = [_]cli.systemd_exporter.EnvVar{
        .{ .key = "PORT", .value = "8080" },
        .{ .key = "APP_ENV", .value = "production" },
    };

    // DotEnv
    var env_buf: [512]u8 = undefined;
    var env_writer = std.Io.Writer.fixed(&env_buf);
    try cli.systemd_exporter.exportDotEnv(&env_writer, &vars);
    const env_out = env_buf[0 .. env_buf.len - env_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, env_out, "PORT=\"8080\"") != null);

    // Systemd Service
    var srv_buf: [1024]u8 = undefined;
    var srv_writer = std.Io.Writer.fixed(&srv_buf);
    try cli.systemd_exporter.exportSystemdService(
        &srv_writer,
        "mycli-daemon",
        "MyCLI Background Service",
        "/usr/local/bin/mycli",
        &vars,
    );
    const srv_out = srv_buf[0 .. srv_buf.len - srv_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, srv_out, "[Unit]") != null);
    try testing.expect(std.mem.indexOf(u8, srv_out, "ExecStart=/usr/local/bin/mycli") != null);
    try testing.expect(std.mem.indexOf(u8, srv_out, "Environment=\"PORT=8080\"") != null);
}

// --- Unknown-command rejection (ROADMAP 3b-1) --------------------------------
//
// These pin the defect that made every unimplemented command a silent success. The
// specification lists ~26 features that did not exist, and before the routing offset
// every one of them exited 0: `config get port` printed the whole resolved
// configuration, because the unmatched token fell through to the parent's `run`. A
// script could not tell a working command from a missing one.
//
// Driven through `execute` rather than `TestHarness` on purpose. The harness
// reconstructs its `Allocating` writers on every `run`, so its `out_buf`/`err_buf` are
// not readable afterwards - the existing typo test at `cli_test.zig:762` uses this same
// direct style for exactly that reason.

/// A root with one real subcommand and a body of its own - the shape `config` has,
/// which is the shape the defect lived in.
const RejectRoot = App.Command(struct {}, .{RejectChild}){
    .name = "proot",
    .run = rejectRootRun,
};

fn rejectRootRun(ctx: App.Ctx, flags: App.Flags(struct {})) !void {
    _ = flags;
    try ctx.out.writeAll("ROOT BODY RAN\n");
}

const RejectChildFlags = struct {
    positionals: struct {
        value: []const u8 = "",
    } = .{},
    pub const meta = .{};
};

const RejectChild = App.Command(RejectChildFlags, .{}){
    .name = "child",
    .description = "takes one positional",
    .run = rejectChildRun,
};

fn rejectChildRun(ctx: App.Ctx, flags: App.Flags(RejectChildFlags)) !void {
    try ctx.out.print("CHILD value={s}\n", .{flags.positionals.value});
}

/// Runs `args` against `RejectRoot` and returns the error, with output captured in
/// caller-owned buffers so it can be inspected after the call.
const RejectRun = struct {
    out_buf: [1024]u8 = undefined,
    err_buf: [1024]u8 = undefined,
    out: std.Io.Writer = undefined,
    err: std.Io.Writer = undefined,
    in_reader: std.Io.Reader = undefined,

    fn init(self: *RejectRun) void {
        self.out = std.Io.Writer.fixed(&self.out_buf);
        self.err = std.Io.Writer.fixed(&self.err_buf);
        var in_zero: [1]u8 = undefined;
        self.in_reader = std.Io.Reader.fixed(&in_zero);
    }

    fn call(self: *RejectRun, chain: *App.ExecutionChain, args: []const []const u8) !void {
        var dummy: usize = 0;
        var env_map = std.process.Environ.Map.init(testing.allocator);
        defer env_map.deinit();

        const ctx = App.Ctx{
            .allocator = testing.allocator,
            .in = &self.in_reader,
            .out = &self.out,
            .err = &self.err,
            .state = &dummy,
            .env_map = &env_map,
            .io = std.testing.io,
        };
        try App.execute(RejectRoot, ctx, args, chain);
    }

    fn stdout(self: *RejectRun) []const u8 {
        return self.out_buf[0 .. self.out_buf.len - self.out.unusedCapacityLen()];
    }

    fn stderr(self: *RejectRun) []const u8 {
        return self.err_buf[0 .. self.err_buf.len - self.err.unusedCapacityLen()];
    }
};

test "an unmatched subcommand on a command with a body is rejected, not run" {
    var r = RejectRun{};
    r.init();
    var chain = try App.ExecutionChain.init(testing.allocator, 2);
    defer chain.deinit(testing.allocator);

    var args = [_][]const u8{ "proot", "nosuch" };
    try testing.expectError(error.UnknownCommand, r.call(&chain, &args));

    try testing.expect(std.mem.indexOf(u8, r.stderr(), "Unknown command 'nosuch'") != null);
    // The parent's body must NOT have run, which is what "silent success" looked like.
    try testing.expect(std.mem.indexOf(u8, r.stdout(), "ROOT BODY RAN") == null);
}

test "an unmatched subcommand is not satisfied by a later valid one" {
    var r = RejectRun{};
    r.init();
    var chain = try App.ExecutionChain.init(testing.allocator, 3);
    defer chain.deinit(testing.allocator);

    // `config foo export` ran `export` before the fix: routing scanned the whole tail
    // for any recognised name and ignored the unknown token in front of it.
    var args = [_][]const u8{ "proot", "nosuch", "child" };
    try testing.expectError(error.UnknownCommand, r.call(&chain, &args));
    try testing.expect(std.mem.indexOf(u8, r.stdout(), "CHILD") == null);
}

test "a valid subcommand still routes and keeps its positional" {
    var r = RejectRun{};
    r.init();
    var chain = try App.ExecutionChain.init(testing.allocator, 3);
    defer chain.deinit(testing.allocator);

    // Guards the regression the earlier attempts caused: slicing `args` when recursing
    // made the leaf lose its first positional, so `config inspect port` printed every
    // field instead of one.
    var args = [_][]const u8{ "proot", "child", "hello" };
    try r.call(&chain, &args);
    try testing.expect(std.mem.indexOf(u8, r.stdout(), "CHILD value=hello") != null);
}

test "rejection suggests the nearest subcommand" {
    var r = RejectRun{};
    r.init();
    var chain = try App.ExecutionChain.init(testing.allocator, 2);
    defer chain.deinit(testing.allocator);

    var args = [_][]const u8{ "proot", "chld" };
    try testing.expectError(error.UnknownCommand, r.call(&chain, &args));
    try testing.expect(std.mem.indexOf(u8, r.stderr(), "Did you mean 'child'?") != null);
}

// --- Kebab-case flags for snake_case fields ----------------------------------

test "a dashed flag resolves to the snake_case field, through the parser" {
    // A Zig field cannot contain `-`, so `dry_run` was reachable only as `--dry_run`.
    // The convention a user expects is `--dry-run`, and the mismatch surfaced as
    // `Unknown flag 'dry-run'` - measured on `config format --dry-run`.
    //
    // This drives the real parser. An earlier version of this test re-implemented the
    // normalisation locally and asserted against its own copy, so it passed while the
    // feature was absent - the failure mode a test is supposed to prevent.
    const DashFlags = struct {
        dry_run: bool = false,
        no_align: bool = false,
        port: u16 = 0,
    };

    const Cmd = comptime App.command(.{ .name = "dash", .flags = DashFlags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(DashFlags)) !void {
            try ctx.out.print("{}|{}|{d}", .{ flags.dry_run, flags.no_align, flags.port });
        }
    }.run);

    var out_buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err = std.Io.Writer.fixed(&err_buf);
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    var args = [_][]const u8{ "--dry-run", "--no-align", "--port=7" };
    try runCmd(App, @TypeOf(Cmd), &args, &out, &err, &env_map);
    try testing.expectEqualStrings("true|true|7", out.buffered());

    // The underscore spelling keeps working, and a near-miss is still unknown.
    out = std.Io.Writer.fixed(&out_buf);
    var args2 = [_][]const u8{ "--dry_run", "--port", "9" };
    try runCmd(App, @TypeOf(Cmd), &args2, &out, &err, &env_map);
    try testing.expectEqualStrings("true|false|9", out.buffered());

    out = std.Io.Writer.fixed(&out_buf);
    var args3 = [_][]const u8{"--dry-run-extra"};
    try testing.expectError(error.UnknownFlag, runCmd(App, @TypeOf(Cmd), &args3, &out, &err, &env_map));
}

// --- Ergonomic registration: `App.command(meta, run)` ------------------------
//
// The metadata lives in one object and the body in another. The body's own shape
// decides which of these it is, so an author writes the parameters they want:
//
//   fn (ctx)                 fn (ctx, flags)        fn (ctx, args)
//   fn (ctx, flags, args)    fn (ctx, args, flags)
//
// Where a test needs a different framework configuration (a config file, a help
// renderer, a built-in version), it declares its own `App` and uses that instance
// consistently - a command is specialised to the app it was built from.

/// Runs one command *type* through `AppT`, with in-memory streams.
///
/// The type rather than a value, because `App.command` produces a command whose every
/// field has a default: `CmdT{}` is the command. Passing a value would need the value
/// itself to be comptime-known, which a `const` local inside a test body is not.
fn runCmd(
    comptime AppT: type,
    comptime CmdT: type,
    args: []const []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    env_map: *std.process.Environ.Map,
) !void {
    var state: usize = 0;
    return runCmdState(AppT, CmdT, args, out, err, env_map, &state);
}

/// `runCmd`, with the state value the caller owns - for a body that records
/// something where the assertion can see it.
fn runCmdState(
    comptime AppT: type,
    comptime CmdT: type,
    args: []const []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    env_map: *std.process.Environ.Map,
    state: *usize,
) !void {
    var in_buf: [64]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(&in_buf);
    const ctx = AppT.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = out,
        .err = err,
        .state = state,
        .env_map = env_map,
        // A real `Io`, not `undefined`: several tests below read config files, and a
        // command under the harness should do platform I/O rather than walk into
        // undefined behaviour.
        .io = std.testing.io,
    };
    const cmd: CmdT = .{};
    var chain = try AppT.ExecutionChain.init(testing.allocator, args.len + 8);
    defer chain.deinit(testing.allocator);
    try AppT.execute(cmd, ctx, args, &chain);
}

/// The in-memory rig the tests below share: two writers and an environment map.
///
/// The buffers are fields so nothing is allocated, and `reset` puts the writers back
/// at the start so one test can drive several invocations and inspect each one.
const Rig = struct {
    out_buf: [8192]u8 = undefined,
    err_buf: [8192]u8 = undefined,
    out: std.Io.Writer = undefined,
    err: std.Io.Writer = undefined,
    env: std.process.Environ.Map = undefined,

    fn init(self: *Rig) void {
        self.out = std.Io.Writer.fixed(&self.out_buf);
        self.err = std.Io.Writer.fixed(&self.err_buf);
        self.env = std.process.Environ.Map.init(testing.allocator);
    }

    fn deinit(self: *Rig) void {
        self.env.deinit();
    }

    fn reset(self: *Rig) void {
        self.out = std.Io.Writer.fixed(&self.out_buf);
        self.err = std.Io.Writer.fixed(&self.err_buf);
    }

    fn stdout(self: *Rig) []const u8 {
        return self.out.buffered();
    }

    fn stderr(self: *Rig) []const u8 {
        return self.err.buffered();
    }
};

test "command: fn(ctx, flags, args) keeps positionals out of the flags" {
    const Flags = struct { loud: bool = false };
    const Args = struct { name: []const u8 = "" };

    const Cmd = comptime App.command(.{
        .name = "greet",
        .description = "Greet someone",
        .flags = Flags,
        .args = Args,
    }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags), args: Args) !void {
            try ctx.out.print("{s}{s}", .{ args.name, if (flags.loud) "!" else "" });
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "greet", "world", "--loud" };
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("world!", rig.stdout());

    // The same argument with the flag first: order on the command line is the user's.
    rig.reset();
    var args2 = [_][]const u8{ "--loud", "there" };
    try runCmd(App, @TypeOf(Cmd), &args2, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("there!", rig.stdout());
}

test "command: fn(ctx, args, flags) is detected too" {
    const Flags = struct { repeat: u8 = 1 };
    const Args = struct { word: []const u8 = "" };

    const Cmd = comptime App.command(.{
        .name = "echo",
        .flags = Flags,
        .args = Args,
    }, struct {
        fn run(ctx: App.Ctx, args: Args, flags: App.Flags(Flags)) !void {
            var i: u8 = 0;
            while (i < flags.repeat) : (i += 1) try ctx.out.print("{s}", .{args.word});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "hi", "--repeat", "3" };
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("hihihi", rig.stdout());
}

test "command: a body may also take only the context, or only the flags" {
    const Simple = struct { n: u8 = 0 };

    const CtxOnly = comptime App.command(.{ .name = "ctx_only" }, struct {
        fn run(ctx: App.Ctx) !void {
            try ctx.out.writeAll("ctx");
        }
    }.run);

    const FlagsOnly = comptime App.command(.{ .name = "flags_only", .flags = Simple }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Simple)) !void {
            try ctx.out.print("{d}", .{flags.n});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{};
    try runCmd(App, @TypeOf(CtxOnly), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("ctx", rig.stdout());

    // The two-parameter form with no `args` in the metadata is `(ctx, flags)`.
    rig.reset();
    var args2 = [_][]const u8{ "--n", "5" };
    try runCmd(App, @TypeOf(FlagsOnly), &args2, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("5", rig.stdout());
}

test "command: a returned value is rendered, as CommandWithReturn did" {
    const Row = struct { name: []const u8, size: u32 };

    const Cmd = comptime App.command(.{ .name = "row" }, struct {
        fn run(ctx: App.Ctx) !Row {
            _ = ctx;
            return .{ .name = "alpha", .size = 3 };
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // `--output json` reaches the body as `output_format`, and the framework renders
    // the returned struct.
    var args = [_][]const u8{"--output=json"};
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "\"name\":\"alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "\"size\":3") != null);
}

test "command: a body-less command routes and prints its help" {
    const Child = comptime App.command(.{ .name = "child", .description = "A child" }, null);
    const Root = comptime App.command(.{
        .name = "root",
        .description = "A root",
        .subcommands = .{Child},
    }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{"child"};
    try runCmd(App, @TypeOf(Root), &args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "Usage: child") != null);
}

test "command: the metadata object may be a named constant" {
    const Flags = struct { level: u8 = 0 };
    const meta = .{
        .name = "named",
        .description = "Registered from a named metadata object",
        .flags = Flags,
        .aliases = &.{"n"},
    };

    const Cmd = comptime App.command(meta, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("level={d}", .{flags.level});
        }
    }.run);

    // Reached through a parent, which is where an alias means anything: the token that
    // selects a command is matched against its name *or* its aliases.
    const Parent = comptime App.command(.{
        .name = "parent",
        .subcommands = .{Cmd},
    }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "n", "--level", "2" };
    try runCmd(App, @TypeOf(Parent), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("level=2", rig.stdout());
}

// --- Parsing -----------------------------------------------------------------

test "short-flag grouping assigns every letter, and a value flag ends the group" {
    const Flags = struct {
        force: bool = false,
        all: bool = false,
        verbose: u8 = 0,
        tag: []const u8 = "",
        pub const meta = .{
            .force = .{ .short = 'f' },
            .all = .{ .short = 'a' },
            .verbose = .{ .short = 'v', .count = true },
            .tag = .{ .short = 't' },
        };
    };

    const Cmd = comptime App.command(.{ .name = "grp", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("{}|{}|{d}|{s}", .{ flags.force, flags.all, flags.verbose, flags.tag });
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // `-favv` is four flags; each letter that is a boolean is set, and the count
    // accumulates per occurrence.
    var args = [_][]const u8{"-favv"};
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("true|true|2|", rig.stdout());

    // A value-taking flag ends the cluster: `-tvalue` is `-t value`, so `value` is
    // not read as more flags.
    rig.reset();
    var args2 = [_][]const u8{"-tvalue"};
    try runCmd(App, @TypeOf(Cmd), &args2, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("false|false|0|value", rig.stdout());

    // And after a boolean cluster: `-fat=tagged`.
    rig.reset();
    var args3 = [_][]const u8{"-fat=tagged"};
    try runCmd(App, @TypeOf(Cmd), &args3, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("true|true|0|tagged", rig.stdout());
}

test "long flags accept both --flag=value and --flag value" {
    const Flags = struct {
        host: []const u8 = "",
        port: u16 = 0,
    };

    const Cmd = comptime App.command(.{ .name = "net", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("{s}:{d}", .{ flags.host, flags.port });
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "--host=a.example", "--port", "8080" };
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("a.example:8080", rig.stdout());
}

test "repeated flags collect every occurrence into a slice" {
    const Flags = struct {
        header: []const []const u8 = &.{},
        include: []const u16 = &.{},
        pub const meta = .{
            .header = .{ .short = 'H', .help = "An HTTP header" },
            .include = .{ .short = 'i' },
        };
    };

    const Cmd = comptime App.command(.{ .name = "fetch", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            for (flags.header, 0..) |h, i| {
                if (i > 0) try ctx.out.writeAll(",");
                try ctx.out.writeAll(h);
            }
            try ctx.out.writeAll("|");
            for (flags.include, 0..) |n, i| {
                if (i > 0) try ctx.out.writeAll(",");
                try ctx.out.print("{d}", .{n});
            }
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "-H", "Accept: json", "--header=Auth: x", "-i", "3", "--include", "7" };
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("Accept: json,Auth: x|3,7", rig.stdout());

    // Nothing given: empty lists, not undefined values.
    rig.reset();
    var args2 = [_][]const u8{};
    try runCmd(App, @TypeOf(Cmd), &args2, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("|", rig.stdout());
}

test "positional arguments: required ones are refused when missing, variadic ones are collected" {
    const Args = struct {
        first: []const u8,
        rest: []const []const u8 = &.{},
    };

    const Cmd = comptime App.command(.{ .name = "collect", .args = Args }, struct {
        fn run(ctx: App.Ctx, args: Args) !void {
            try ctx.out.print("{s}|{d}", .{ args.first, args.rest.len });
            for (args.rest) |r| try ctx.out.print("|{s}", .{r});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "a", "b", "c" };
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("a|2|b|c", rig.stdout());

    // No argument at all: the first positional has no default, so it is required.
    // (The error is what a non-interactive caller sees; the harness is not a TTY.)
    rig.reset();
    var none = [_][]const u8{};
    try testing.expectError(
        error.MissingRequiredPositionalArgument,
        runCmd(App, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env),
    );
}

test "mutually exclusive groups are declared once, on the command" {
    const Flags = struct {
        use_tcp: bool = false,
        use_udp: bool = false,
        use_quic: bool = false,
    };

    const Cmd = comptime App.command(.{
        .name = "transport",
        .flags = Flags,
        .mutually_exclusive = &.{&.{ "use_tcp", "use_udp", "use_quic" }},
    }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("{}-{}-{}", .{ flags.use_tcp, flags.use_udp, flags.use_quic });
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // One of the three is fine.
    var ok = [_][]const u8{"--use-tcp"};
    try runCmd(App, @TypeOf(Cmd), &ok, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("true-false-false", rig.stdout());

    // Two is a usage error, and the message names both.
    rig.reset();
    var bad = [_][]const u8{ "--use-tcp", "--use-quic" };
    try testing.expectError(error.ConflictingFlags, runCmd(App, @TypeOf(Cmd), &bad, &rig.out, &rig.err, &rig.env));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "cannot be used with") != null);
}

test "environment fallback: default, then environment, then the command line" {
    const Flags = struct {
        port: u16 = 3000,
        pub const meta = .{ .port = .{ .env = "APP_PORT" } };
    };

    const Cmd = comptime App.command(.{ .name = "env_cmd", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("{d}", .{flags.port});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // Nothing anywhere: the struct's default.
    var none = [_][]const u8{};
    try runCmd(App, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("3000", rig.stdout());

    // The environment supplies it.
    try rig.env.put("APP_PORT", "8080");
    rig.reset();
    try runCmd(App, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("8080", rig.stdout());

    // The command line wins over the environment, which is the whole point of an
    // explicit flag.
    rig.reset();
    var given = [_][]const u8{ "--port", "9999" };
    try runCmd(App, @TypeOf(Cmd), &given, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("9999", rig.stdout());
}

test "environment fallback satisfies a flag that has no default" {
    // A required flag is one with no default; the environment must be able to answer
    // it, or `meta.<field>.env` is a promise the framework does not keep.
    const Flags = struct {
        token: []const u8,
        pub const meta = .{ .token = .{ .env = "APP_TOKEN" } };
    };

    const Cmd = comptime App.command(.{ .name = "auth_cmd", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("{s}", .{flags.token});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var none = [_][]const u8{};
    try testing.expectError(
        error.MissingRequiredFlag,
        runCmd(App, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env),
    );

    try rig.env.put("APP_TOKEN", "from-env");
    rig.reset();
    try runCmd(App, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("from-env", rig.stdout());
}

test "a repeated flag can be supplied from the environment as a comma-separated list" {
    const Flags = struct {
        host: []const []const u8 = &.{},
        pub const meta = .{ .host = .{ .env = "APP_HOSTS" } };
    };

    const Cmd = comptime App.command(.{ .name = "hosts_cmd", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            for (flags.host, 0..) |h, i| {
                if (i > 0) try ctx.out.writeAll(",");
                try ctx.out.writeAll(h);
            }
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();
    try rig.env.put("APP_HOSTS", "a.example, b.example");

    var none = [_][]const u8{};
    try runCmd(App, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("a.example,b.example", rig.stdout());
}

// --- Type safety: custom parsers and validation ------------------------------

test "a per-field `parse` declaration is reachable" {
    // The lookup used to happen on the *merged* flags type, which `MergeFlags`
    // synthesizes with fields and no declarations - so a custom parser was invisible
    // and every value fell through to the built-in coercions. This asserts the
    // declaration actually runs, by using a type the built-ins cannot parse.
    const Ipv4 = struct { text: []const u8 };

    const parseIpv4 = struct {
        fn parse(text: []const u8) !Ipv4 {
            if (std.mem.indexOfScalar(u8, text, '.') == null) return error.NotAnAddress;
            return .{ .text = text };
        }
    }.parse;

    const Flags = struct {
        address: Ipv4 = .{ .text = "0.0.0.0" },
        pub const parse = .{ .address = parseIpv4 };
    };

    const Cmd = comptime App.command(.{ .name = "dial", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("{s}", .{flags.address.text});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "--address", "10.0.0.1" };
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("10.0.0.1", rig.stdout());

    // The parser's own error is what the caller sees, not a generic one.
    rig.reset();
    var bad = [_][]const u8{ "--address", "not-an-address" };
    try testing.expectError(error.NotAnAddress, runCmd(App, @TypeOf(Cmd), &bad, &rig.out, &rig.err, &rig.env));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "Invalid format") != null);
}

test "a `validation` rules block is enforced" {
    // The same declaration-visibility bug as `parse`: the block was read off the
    // synthesized type, so it never ran.
    const Flags = struct {
        count: u32 = 5,
        mode: []const u8 = "fast",

        pub const validation = .{
            .count = .{ .min = 1, .max = 10 },
            .mode = .{ .in = &.{ "fast", "slow" } },
        };
    };

    const Cmd = comptime App.command(.{ .name = "bounded", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("{d}:{s}", .{ flags.count, flags.mode });
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var ok = [_][]const u8{ "--count", "3", "--mode", "slow" };
    try runCmd(App, @TypeOf(Cmd), &ok, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("3:slow", rig.stdout());

    rig.reset();
    var too_big = [_][]const u8{ "--count", "99" };
    try testing.expectError(error.ValidationFailed, runCmd(App, @TypeOf(Cmd), &too_big, &rig.out, &rig.err, &rig.env));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "greater than maximum") != null);

    rig.reset();
    var not_allowed = [_][]const u8{ "--mode", "sideways" };
    try testing.expectError(error.ValidationFailed, runCmd(App, @TypeOf(Cmd), &not_allowed, &rig.out, &rig.err, &rig.env));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "not in allowed list") != null);
}

// --- Routing, help and the UX surface ----------------------------------------

test "hidden commands are routable but not advertised anywhere" {
    const Visible = comptime App.command(.{ .name = "visible", .description = "Shown" }, null);
    const Secret = comptime App.command(.{
        .name = "secret",
        .description = "Not shown",
        .hidden = true,
    }, struct {
        fn run(ctx: App.Ctx) !void {
            try ctx.out.writeAll("secret ran");
        }
    }.run);
    const Root = comptime App.command(.{
        .name = "hroot",
        .description = "Root",
        .subcommands = .{ Visible, Secret },
    }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // Routable.
    var run_args = [_][]const u8{"secret"};
    try runCmd(App, @TypeOf(Root), &run_args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("secret ran", rig.stdout());

    // Absent from --help.
    rig.reset();
    var help_args = [_][]const u8{"--help"};
    try runCmd(App, @TypeOf(Root), &help_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "visible") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "secret") == null);

    // Absent from the completion list.
    rig.reset();
    var comp_args = [_][]const u8{"__complete"};
    try runCmd(App, @TypeOf(Root), &comp_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "visible") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "secret") == null);

    // Absent from the generated documentation.
    rig.reset();
    var doc_args = [_][]const u8{ "generate-docs", "markdown" };
    try runCmd(App, @TypeOf(Root), &doc_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "**visible**") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "**secret**") == null);

    // And never suggested as a correction, which would advertise it just as loudly.
    rig.reset();
    var typo_args = [_][]const u8{"secre"};
    try testing.expectError(error.UnknownCommand, runCmd(App, @TypeOf(Root), &typo_args, &rig.out, &rig.err, &rig.env));
}

test "a command alias routes, and is listed in help and completions" {
    const Deploy = comptime App.command(.{
        .name = "deploy",
        .description = "Deploy the thing",
        .aliases = &.{"d"},
    }, struct {
        fn run(ctx: App.Ctx) !void {
            try ctx.out.writeAll("deployed");
        }
    }.run);
    const Root = comptime App.command(.{
        .name = "aroot",
        .description = "Root",
        .subcommands = .{Deploy},
    }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{"d"};
    try runCmd(App, @TypeOf(Root), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("deployed", rig.stdout());

    rig.reset();
    var help_args = [_][]const u8{"--help"};
    try runCmd(App, @TypeOf(Root), &help_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "deploy (d)") != null);

    rig.reset();
    var comp_args = [_][]const u8{"__complete"};
    try runCmd(App, @TypeOf(Root), &comp_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "deploy") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "d\n") != null);
}

test "commands nest to depth three and the leaf still gets its flags" {
    const LeafFlags = struct { tag: []const u8 = "" };
    const LeafRig = struct {
        var seen: []const u8 = "";
    };

    const Leaf = comptime App.command(.{ .name = "leaf", .flags = LeafFlags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(LeafFlags)) !void {
            _ = ctx;
            LeafRig.seen = flags.tag;
        }
    }.run);

    const Mid = comptime App.command(.{ .name = "mid", .subcommands = .{Leaf} }, null);
    const Root = comptime App.command(.{ .name = "depthroot", .subcommands = .{Mid} }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "mid", "leaf", "--tag", "value" };
    try runCmd(App, @TypeOf(Root), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("value", LeafRig.seen);
    try testing.expectEqualStrings("", rig.stderr());
}

test "pre_run and post_run hooks run around the body, root first for pre" {
    // `pre_runs` was collected and never called anywhere in the framework: a hook that
    // looked supported and did nothing.
    const order = struct {
        var trace: [8]u8 = @splat(0);
        var len: usize = 0;

        fn pre(ctx: App.Ctx) App.Error!void {
            trace[len] = 'p';
            len += 1;
            _ = ctx;
        }

        fn post(ctx: App.Ctx) App.Error!void {
            trace[len] = 'P';
            len += 1;
            _ = ctx;
        }
    };

    const Child = comptime App.command(.{
        .name = "child",
        .pre_run = order.pre,
        .post_run = order.post,
    }, struct {
        fn run(ctx: App.Ctx) !void {
            order.trace[order.len] = 'b';
            order.len += 1;
            _ = ctx;
        }
    }.run);

    const Root = comptime App.command(.{
        .name = "hookroot",
        .pre_run = order.pre,
        .post_run = order.post,
        .subcommands = .{Child},
    }, null);

    order.len = 0;
    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{"child"};
    try runCmd(App, @TypeOf(Root), &args, &rig.out, &rig.err, &rig.env);

    // Root pre, leaf pre, body, leaf post, root post - the two hooks bracket the body
    // in the order a middleware would.
    try testing.expectEqualSlices(u8, "ppbPP", order.trace[0..5]);
}

test "help aligns its columns, shows defaults, arguments and dashed spellings" {
    const Flags = struct {
        dry_run: bool = false,
        retries: u8 = 3,
        tag: []const u8 = "none",
        pub const meta = .{
            .dry_run = .{ .help = "Do not write" },
            .retries = .{ .short = 'r', .help = "Attempts" },
            .tag = .{ .help = "A label" },
        };
    };
    const Args = struct {
        target: []const u8 = "",
        pub const meta = .{ .target = .{ .help = "What to act on" } };
    };

    const Cmd = comptime App.command(.{
        .name = "aligned",
        .description = "A command with everything to show",
        .flags = Flags,
        .args = Args,
    }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags), args: Args) !void {
            _ = ctx;
            _ = flags;
            _ = args;
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{"--help"};
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    const text = rig.stdout();

    // Usage names both capabilities, because the command has both.
    try testing.expect(std.mem.indexOf(u8, text, "Usage: aligned [args]") != null);
    // Arguments have a section of their own, documented from the args struct's meta.
    try testing.expect(std.mem.indexOf(u8, text, "Arguments:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "target") != null);
    try testing.expect(std.mem.indexOf(u8, text, "What to act on") != null);
    // A snake_case field is advertised with dashes, and the default is shown.
    try testing.expect(std.mem.indexOf(u8, text, "--dry-run") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Do not write") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--retries, -r") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[default: 3]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[default: none]") != null);
    // `--tag` has no default of its own? It has one, so it is not marked required.
    try testing.expect(std.mem.indexOf(u8, text, "[required]") == null);
}

test "help can be replaced per command, and for the whole app" {
    const Custom = struct {
        pub fn render(ctx: anytype, cmd: anytype) !void {
            try ctx.out.print("CUSTOM {s}\n", .{cmd.name});
        }
    };

    const Cmd = comptime App.command(.{ .name = "over", .help = Custom }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{"--help"};
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("CUSTOM over\n", rig.stdout());

    // The application-level override applies to commands that do not declare one.
    const HelpApp = cli.App(usize, .{ .help_renderer = Custom });
    const Plain = comptime HelpApp.command(.{ .name = "plain" }, null);

    var help_rig: Rig = .{};
    help_rig.init();
    defer help_rig.deinit();
    var plain_args = [_][]const u8{"--help"};
    try runCmd(HelpApp, @TypeOf(Plain), &plain_args, &help_rig.out, &help_rig.err, &help_rig.env);
    try testing.expectEqualStrings("CUSTOM plain\n", help_rig.stdout());
}

test "the built-in --version and -V print the configured version" {
    const VersionApp = cli.App(usize, .{ .version = "9.9.9" });

    const Cmd = comptime VersionApp.command(.{ .name = "vprog" }, struct {
        fn run(ctx: VersionApp.Ctx) !void {
            try ctx.out.writeAll("body ran");
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var long = [_][]const u8{"--version"};
    try runCmd(VersionApp, @TypeOf(Cmd), &long, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("vprog 9.9.9\n", rig.stdout());

    rig.reset();
    var short = [_][]const u8{"-V"};
    try runCmd(VersionApp, @TypeOf(Cmd), &short, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("vprog 9.9.9\n", rig.stdout());

    // The body never runs; with no version configured the built-in is inert, so
    // `--version` is simply an unknown flag to that app.
    rig.reset();
    var plain = [_][]const u8{"--version"};
    try testing.expectError(error.UnknownFlag, runCmd(App, @TypeOf(Cmd), &plain, &rig.out, &rig.err, &rig.env));
    try testing.expectEqualStrings("", rig.stdout());
}

test "an unknown flag suggests the nearest one" {
    const Flags = struct {
        verbose: bool = false,
        cache: bool = false,
        dry_run: bool = false,
        pub const meta = .{ .verbose = .{ .short = 'v' } };
    };

    const Cmd = comptime App.command(.{ .name = "typo_flag", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            _ = ctx;
            _ = flags;
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{"--verbos"};
    try testing.expectError(error.UnknownFlag, runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "Error: Unknown flag 'verbos'.") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "Did you mean '--verbose'?") != null);

    // A dashed typo is measured against the field, not charged for the dash as well.
    rig.reset();
    var dashed = [_][]const u8{"--dry-rnu"};
    try testing.expectError(error.UnknownFlag, runCmd(App, @TypeOf(Cmd), &dashed, &rig.out, &rig.err, &rig.env));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "Did you mean '--dry-run'?") != null);

    // Nothing close enough: no suggestion rather than a wrong one.
    rig.reset();
    var far = [_][]const u8{"--zzzzzz"};
    try testing.expectError(error.UnknownFlag, runCmd(App, @TypeOf(Cmd), &far, &rig.out, &rig.err, &rig.env));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "Did you mean") == null);
}

test "shell completions: the zsh script and the __complete protocol" {
    const Alpha = comptime App.command(.{ .name = "alpha", .description = "A" }, null);
    const Beta = comptime App.command(.{ .name = "beta", .description = "B" }, null);
    const Root = comptime App.command(.{
        .name = "comproot",
        .subcommands = .{ Alpha, Beta },
    }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // The zsh arm used to be shadowed by a hardcoded duplicate earlier in the
    // dispatcher, so `emitZshCompletions` was unreachable.
    var zsh = [_][]const u8{ "generate-completions", "zsh" };
    try runCmd(App, @TypeOf(Root), &zsh, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.startsWith(u8, rig.stdout(), "#compdef comproot"));
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "compdef _comproot comproot") != null);

    // The runtime protocol lists subcommands.
    rig.reset();
    var complete = [_][]const u8{"__complete"};
    try runCmd(App, @TypeOf(Root), &complete, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("alpha\nbeta\n", rig.stdout());

    // argv-style, where args[0] is the program's own name: the interceptors used to
    // read args[0] and route `comproot __complete` as a command called `comproot`.
    rig.reset();
    var argv_style = [_][]const u8{ "comproot", "__complete" };
    try runCmd(App, @TypeOf(Root), &argv_style, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("alpha\nbeta\n", rig.stdout());

    // The other three shells still emit their own scripts.
    for ([_][]const u8{ "bash", "fish", "powershell" }) |shell| {
        rig.reset();
        var shell_args = [_][]const u8{ "generate-completions", shell };
        try runCmd(App, @TypeOf(Root), &shell_args, &rig.out, &rig.err, &rig.env);
        try testing.expect(std.mem.indexOf(u8, rig.stdout(), "comproot") != null);
    }
}

test "man pages and markdown list arguments, and markdown carries the flags table" {
    const Flags = struct {
        force: bool = false,
        pub const meta = .{ .force = .{ .help = "Force it" } };
    };
    const Args = struct {
        target: []const u8 = "",
        pub const meta = .{ .target = .{ .help = "The target" } };
    };

    const Cmd = comptime App.command(.{
        .name = "doccmd",
        .description = "Documented",
        .flags = Flags,
        .args = Args,
    }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags), args: Args) !void {
            _ = ctx;
            _ = flags;
            _ = args;
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var md = [_][]const u8{ "generate-docs", "markdown" };
    try runCmd(App, @TypeOf(Cmd), &md, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "# doccmd") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "| --force |") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "### Arguments") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "| target |") != null);

    rig.reset();
    var man = [_][]const u8{ "generate-docs", "man" };
    try runCmd(App, @TypeOf(Cmd), &man, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), ".TH doccmd 1") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), ".SH NAME") != null);
}

// --- Environment and configuration files -------------------------------------

/// Writes `text` to `path`, so a test can point a config file at it.
fn writeTestFile(path: []const u8, text: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, text, 0);
}

test "config file: the CLI beats the environment, which beats the file, which beats the default" {
    const path = "test_cli_layers.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try writeTestFile(path, "{\"host\": \"from-file\", \"port\": 9100}");

    const FileApp = cli.App(usize, .{ .config_file = .{ .path = path } });

    // `host` declares an environment binding and a file key; `port` is set from the
    // file with no metadata at all, which is what makes the layer seamless.
    const Flags = struct {
        host: []const u8 = "from-default",
        port: u16 = 1,
        pub const meta = .{
            .host = .{ .env = "SNEK_TEST_HOST", .config = "host" },
        };
    };

    const Cmd = comptime FileApp.command(.{ .name = "svc", .flags = Flags }, struct {
        fn run(ctx: FileApp.Ctx, flags: FileApp.Flags(Flags)) !void {
            try ctx.out.print("{s}:{d}", .{ flags.host, flags.port });
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();
    var none = [_][]const u8{};

    // File only: both values come from it, and the default is not used.
    try runCmd(FileApp, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("from-file:9100", rig.stdout());

    // The environment beats the file for `host`; `port` still comes from the file.
    try rig.env.put("SNEK_TEST_HOST", "from-env");
    rig.reset();
    try runCmd(FileApp, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("from-env:9100", rig.stdout());

    // The command line beats the environment.
    rig.reset();
    var given = [_][]const u8{ "--host", "from-cli" };
    try runCmd(FileApp, @TypeOf(Cmd), &given, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("from-cli:9100", rig.stdout());

    // With the file gone, the field default is the last resort.
    const MissingApp = cli.App(usize, .{ .config_file = .{ .path = "test_cli_no_such_file.json" } });
    const MissingCmd = comptime MissingApp.command(.{ .name = "svc", .flags = Flags }, struct {
        fn run(ctx: MissingApp.Ctx, flags: MissingApp.Flags(Flags)) !void {
            try ctx.out.print("{s}:{d}", .{ flags.host, flags.port });
        }
    }.run);
    var missing_rig: Rig = .{};
    missing_rig.init();
    defer missing_rig.deinit();
    try runCmd(MissingApp, @TypeOf(MissingCmd), &none, &missing_rig.out, &missing_rig.err, &missing_rig.env);
    try testing.expectEqualStrings("from-default:1", missing_rig.stdout());
}

test "config file: TOML tables flatten to dotted keys, prefixed per app" {
    const path = "test_cli_layers.toml";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    // A comment, a table and a quoted string: the TOML arm of the format dispatcher.
    try writeTestFile(path,
        \\# the service
        \\[svc]
        \\port = 4321
        \\name = "from-toml"
        \\
    );

    const TomlApp = cli.App(usize, .{
        .config_file = .{ .path = path, .prefix = "svc" },
    });

    const Flags = struct {
        port: u16 = 1,
        name: []const u8 = "default",
    };

    const Cmd = comptime TomlApp.command(.{ .name = "svc", .flags = Flags }, struct {
        fn run(ctx: TomlApp.Ctx, flags: TomlApp.Flags(Flags)) !void {
            try ctx.out.print("{s}:{d}", .{ flags.name, flags.port });
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var none = [_][]const u8{};
    try runCmd(TomlApp, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("from-toml:4321", rig.stdout());
}

test "config file: a file with no recognised extension is read as KEY=value" {
    const path = "test_cli_layers.env";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try writeTestFile(path, "PORT=1234\nNAME=from-dotenv\n");

    const DotenvApp = cli.App(usize, .{ .config_file = .{ .path = path } });

    const Flags = struct {
        port: u16 = 1,
        name: []const u8 = "default",
    };

    const Cmd = comptime DotenvApp.command(.{ .name = "svc", .flags = Flags }, struct {
        fn run(ctx: DotenvApp.Ctx, flags: DotenvApp.Flags(Flags)) !void {
            try ctx.out.print("{s}:{d}", .{ flags.name, flags.port });
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var none = [_][]const u8{};
    try runCmd(DotenvApp, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("from-dotenv:1234", rig.stdout());
}

test "config file: a malformed file is reported rather than ignored" {
    const path = "test_cli_layers_bad.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try writeTestFile(path, "{not json");

    const BadApp = cli.App(usize, .{ .config_file = .{ .path = path } });
    const Flags = struct { port: u16 = 1 };

    const Cmd = comptime BadApp.command(.{ .name = "svc", .flags = Flags }, struct {
        fn run(ctx: BadApp.Ctx, flags: BadApp.Flags(Flags)) !void {
            try ctx.out.print("{d}", .{flags.port});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var none = [_][]const u8{};
    try testing.expectError(error.Malformed, runCmd(BadApp, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "cannot parse config file") != null);
}

test "config file: a custom loader replaces the built-in dispatcher" {
    // The loader is a parser, not a reader: the framework opens the file, so a loader
    // never has to deal with a missing path or an unreadable stream.
    const Loader = struct {
        fn load(
            arena: std.mem.Allocator,
            path: []const u8,
            text: []const u8,
        ) anyerror!std.StringHashMapUnmanaged([]const u8) {
            _ = path;
            var values: std.StringHashMapUnmanaged([]const u8) = .empty;
            // A deliberately trivial grammar: `key:value` per line.
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \r\t");
                if (trimmed.len == 0) continue;
                const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
                try values.put(arena, trimmed[0..colon], trimmed[colon + 1 ..]);
            }
            return values;
        }
    };

    const path = "test_cli_layers_custom.conf";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try writeTestFile(path, "port:7777\n");

    const CustomApp = cli.App(usize, .{
        .config_file = .{ .path = path, .loader = @as(cli.ConfigFile.Loader, Loader.load) },
    });
    const Flags = struct { port: u16 = 1 };

    const Cmd = comptime CustomApp.command(.{ .name = "svc", .flags = Flags }, struct {
        fn run(ctx: CustomApp.Ctx, flags: CustomApp.Flags(Flags)) !void {
            try ctx.out.print("{d}", .{flags.port});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var none = [_][]const u8{};
    try runCmd(CustomApp, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("7777", rig.stdout());
}

test "confirmation gate: a command that requires confirmation refuses without --yes" {
    const Cmd = comptime App.command(.{
        .name = "dangerous",
        .requires_confirmation = true,
    }, struct {
        fn run(ctx: App.Ctx) !void {
            try ctx.out.writeAll("did it");
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // Not a TTY, so the framework refuses rather than assuming consent.
    var none = [_][]const u8{};
    try testing.expectError(
        error.ConfirmationRequired,
        runCmd(App, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env),
    );

    // `--yes` is a global flag, so it is accepted on any command that asks.
    rig.reset();
    var confirmed = [_][]const u8{"--yes"};
    try runCmd(App, @TypeOf(Cmd), &confirmed, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("did it", rig.stdout());
}

// --- The interactive prompt path ---------------------------------------------
//
// Every branch below is guarded by `ctx.is_tty`, which the plain `runCmd` helper
// leaves false - so the prompt half of "required and optional fields" had no test at
// all. `stdin` is a parameter of the harness, so it can be driven.

/// What a test feeds the framework's stdin, and whether it claims to be a terminal.
const Input = struct {
    text: []const u8 = "",
    is_tty: bool = false,
};

/// `runCmd` with a stdin the prompt can read and an `is_tty` the prompt can trust.
fn runCmdInput(
    comptime AppT: type,
    comptime CmdT: type,
    args: []const []const u8,
    input: Input,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    env_map: *std.process.Environ.Map,
) !void {
    var in_reader = std.Io.Reader.fixed(input.text);
    var state: usize = 0;
    const ctx = AppT.Ctx{
        .allocator = testing.allocator,
        .in = &in_reader,
        .out = out,
        .err = err,
        .state = &state,
        .env_map = env_map,
        .io = std.testing.io,
        .is_tty = input.is_tty,
    };
    const cmd: CmdT = .{};
    var chain = try AppT.ExecutionChain.init(testing.allocator, args.len + 8);
    defer chain.deinit(testing.allocator);
    try AppT.execute(cmd, ctx, args, &chain);
}

test "a prompt fills a required flag, and an empty answer is a refusal" {
    const Flags = struct { token: []const u8 };

    const Cmd = comptime App.command(.{ .name = "prompted", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("token={s}", .{flags.token});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();
    var none = [_][]const u8{};

    try runCmdInput(
        App,
        @TypeOf(Cmd),
        &none,
        .{ .text = "abc123\n", .is_tty = true },
        &rig.out,
        &rig.err,
        &rig.env,
    );
    // The prompt names the flag, and the answer becomes its value.
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "? token [--token]: ") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "token=abc123") != null);

    // An empty answer is "no value", not an empty string value.
    rig.reset();
    try testing.expectError(error.MissingRequiredFlag, runCmdInput(
        App,
        @TypeOf(Cmd),
        &none,
        .{ .text = "\n", .is_tty = true },
        &rig.out,
        &rig.err,
        &rig.env,
    ));

    // And the same command on a non-TTY is told, not prompted at.
    rig.reset();
    try testing.expectError(error.MissingRequiredFlag, runCmdInput(
        App,
        @TypeOf(Cmd),
        &none,
        .{ .text = "abc123\n", .is_tty = false },
        &rig.out,
        &rig.err,
        &rig.env,
    ));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "Missing required flag '--token'") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "? token") == null);
}

test "a prompt fills a required positional, and an empty answer is a refusal" {
    const Args = struct { target: []const u8 };

    const Cmd = comptime App.command(.{ .name = "prompted_pos", .args = Args }, struct {
        fn run(ctx: App.Ctx, args: Args) !void {
            try ctx.out.print("target={s}", .{args.target});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();
    var none = [_][]const u8{};

    try runCmdInput(
        App,
        @TypeOf(Cmd),
        &none,
        .{ .text = "host-1\n", .is_tty = true },
        &rig.out,
        &rig.err,
        &rig.env,
    );
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "? target (positional): ") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "target=host-1") != null);

    rig.reset();
    try testing.expectError(error.MissingRequiredPositionalArgument, runCmdInput(
        App,
        @TypeOf(Cmd),
        &none,
        .{ .text = "\n", .is_tty = true },
        &rig.out,
        &rig.err,
        &rig.env,
    ));
}

// --- The remaining error paths ----------------------------------------------

test "a value flag with no value, and too many positionals, are refused" {
    const Flags = struct { token: []const u8 = "" };
    const FlagCmd = comptime App.command(.{ .name = "needs_value", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("{s}", .{flags.token});
        }
    }.run);

    const Args = struct { first: []const u8 = "" };
    const PosCmd = comptime App.command(.{ .name = "one_only", .args = Args }, struct {
        fn run(ctx: App.Ctx, args: Args) !void {
            try ctx.out.print("{s}", .{args.first});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // `--token` is the last token, so there is nothing to take as its value. The
    // message names the flag rather than blaming the command line in general.
    var dangling = [_][]const u8{"--token"};
    try testing.expectError(error.MissingFlagValue, runCmd(
        App,
        @TypeOf(FlagCmd),
        &dangling,
        &rig.out,
        &rig.err,
        &rig.env,
    ));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "requires a value") != null);

    // Two arguments for one positional field: a fixed positional list is not a bucket.
    rig.reset();
    var overflow = [_][]const u8{ "a", "b" };
    try testing.expectError(error.TooManyPositionalArguments, runCmd(
        App,
        @TypeOf(PosCmd),
        &overflow,
        &rig.out,
        &rig.err,
        &rig.env,
    ));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "Too many positional arguments") != null);
}

test "config file: a YAML mapping flattens like the other two formats" {
    const path = "test_cli_layers.yaml";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try writeTestFile(path, "name: from-yaml\nport: 5555\n");

    const YamlApp = cli.App(usize, .{ .config_file = .{ .path = path } });

    const Flags = struct {
        name: []const u8 = "default",
        port: u16 = 1,
    };

    const Cmd = comptime YamlApp.command(.{ .name = "svc", .flags = Flags }, struct {
        fn run(ctx: YamlApp.Ctx, flags: YamlApp.Flags(Flags)) !void {
            try ctx.out.print("{s}:{d}", .{ flags.name, flags.port });
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var none = [_][]const u8{};
    try runCmd(YamlApp, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("from-yaml:5555", rig.stdout());
}

// --- Flag-value completion ---------------------------------------------------
//
// `executeAutocomplete` reads a field's `completion` declaration off the flags type.
// That lookup had the same `MergeFlags`-copies-no-declarations bug as `parse` and
// `validation`, so a completion function was invisible - and no test covered it even
// after the fix, because the completion tests only exercised subcommand names.

test "a flag's completion function supplies its values" {
    const Flags = struct {
        role: []const u8 = "",
        mode: enum { fast, slow } = .fast,

        pub const completion = .{
            .role = struct {
                fn complete(ctx: anytype, args: []const []const u8) []const []const u8 {
                    _ = ctx;
                    _ = args;
                    return &.{ "admin", "operator", "viewer" };
                }
            }.complete,
        };
    };

    const Cmd = comptime App.command(.{ .name = "grant", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("{s}", .{flags.role});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // The shell protocol hands the words typed so far, ending with the empty value the
    // user is about to complete.
    var role_args = [_][]const u8{ "__complete", "--role", "" };
    try runCmd(App, @TypeOf(Cmd), &role_args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("admin\noperator\nviewer\n", rig.stdout());

    // An enum-valued flag needs no declaration: its variants are the candidates.
    rig.reset();
    var mode_args = [_][]const u8{ "__complete", "--mode", "" };
    try runCmd(App, @TypeOf(Cmd), &mode_args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("fast\nslow\n", rig.stdout());

    // Completing the flag *name* lists the flags, with the command-line spelling.
    rig.reset();
    var name_args = [_][]const u8{ "__complete", "--r" };
    try runCmd(App, @TypeOf(Cmd), &name_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "--role") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "--mode") != null);
}

test "the confirmation gate asks on a terminal, and only a yes proceeds" {
    const Cmd = comptime App.command(.{
        .name = "confirm_me",
        .requires_confirmation = true,
    }, struct {
        fn run(ctx: App.Ctx) !void {
            try ctx.out.writeAll("did it");
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();
    var none = [_][]const u8{};

    // An explicit yes runs the body.
    try runCmdInput(
        App,
        @TypeOf(Cmd),
        &none,
        .{ .text = "y\n", .is_tty = true },
        &rig.out,
        &rig.err,
        &rig.env,
    );
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "Run 'confirm_me'? [y/N] ") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "did it") != null);

    // Anything else - "n", or an empty answer where the user just pressed return - is a
    // refusal, and a refusal is a cancellation rather than a failure.
    for ([_][]const u8{ "n\n", "\n" }) |answer| {
        rig.reset();
        try testing.expectError(error.UserCancelled, runCmdInput(
            App,
            @TypeOf(Cmd),
            &none,
            .{ .text = answer, .is_tty = true },
            &rig.out,
            &rig.err,
            &rig.env,
        ));
        try testing.expect(std.mem.indexOf(u8, rig.stderr(), "Aborted") != null);
        try testing.expect(std.mem.indexOf(u8, rig.stdout(), "did it") == null);
    }

    // `--yes` skips the question entirely, on a terminal as much as off one.
    rig.reset();
    var confirmed = [_][]const u8{"--yes"};
    try runCmdInput(
        App,
        @TypeOf(Cmd),
        &confirmed,
        .{ .is_tty = true },
        &rig.out,
        &rig.err,
        &rig.env,
    );
    try testing.expectEqualStrings("did it", rig.stdout());
}

// --- Secret redaction --------------------------------------------------------

test "a secret flag is scrubbed from logs, errors and help" {
    // The chain the framework owns end to end: the metadata marks the value secret, the
    // parser hands it to the log scrubber, error messages mask it, and `--help` never
    // prints its default.
    const Flags = struct {
        token: []const u8 = "default-token-value",
        count: u32 = 0,
        pub const meta = .{
            .token = .{ .secret = true, .help = "API token" },
        };
    };

    const Cmd = comptime App.command(.{ .name = "secure", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            // The kind of line that leaks in practice: a scope and a token pasted into a
            // message by whoever was debugging.
            var buf: [512]u8 = undefined;
            const logger = cli.log.init("secure-cmd");
            var w = std.Io.Writer.fixed(&buf);
            try logger.write(&w, .info, "auth", flags.token);
            try ctx.out.print("{s}", .{w.buffered()});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    cli.log.clearSecrets();
    defer cli.log.clearSecrets();

    var args = [_][]const u8{ "--token", "s3cr3t-token-xyz" };
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);

    // Parsing registered it, and the log line carries the mask rather than the value.
    try testing.expectEqual(@as(usize, 1), cli.log.registeredSecretCount());
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "s3cr3t-token-xyz") == null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), cli.log.redaction_mask) != null);

    // The JSON form scrubs too.
    var json_buf: [512]u8 = undefined;
    var jw = std.Io.Writer.fixed(&json_buf);
    const json_logger = cli.log.init("secure-cmd").withFormat(.json);
    try json_logger.write(&jw, .warn, "auth", "token=s3cr3t-token-xyz failed");
    try testing.expect(std.mem.indexOf(u8, jw.buffered(), "s3cr3t-token-xyz") == null);
    try testing.expect(std.mem.indexOf(u8, jw.buffered(), cli.log.redaction_mask) != null);

    // A bad value on a secret flag is masked in the error message: a token with a typo is
    // still a token.
    cli.log.clearSecrets();
    rig.reset();
    var bad = [_][]const u8{ "--count", "not-a-number" };
    try testing.expectError(error.HandledError, runCmd(App, @TypeOf(Cmd), &bad, &rig.out, &rig.err, &rig.env));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "not-a-number") != null); // not secret

    const SecretInt = struct {
        pin: u32 = 1234,
        pub const meta = .{ .pin = .{ .secret = true } };
    };
    const PinCmd = comptime App.command(.{ .name = "pin_cmd", .flags = SecretInt }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(SecretInt)) !void {
            try ctx.out.print("{d}", .{flags.pin});
        }
    }.run);
    rig.reset();
    var bad_pin = [_][]const u8{ "--pin", "9999abc" };
    try testing.expectError(error.HandledError, runCmd(App, @TypeOf(PinCmd), &bad_pin, &rig.out, &rig.err, &rig.env));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "9999abc") == null);
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), cli.log.redaction_mask) != null);

    // `--help` prints the flag and never its default.
    rig.reset();
    var help_args = [_][]const u8{"--help"};
    try runCmd(App, @TypeOf(Cmd), &help_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "--token") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "default-token-value") == null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), cli.log.redaction_mask) != null);

    // The generated documentation does not leak it either.
    rig.reset();
    var doc_args = [_][]const u8{ "generate-docs", "markdown" };
    try runCmd(App, @TypeOf(Cmd), &doc_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "default-token-value") == null);

    // A crate that logs without the framework's help still gets the value scrubbed once
    // it has been parsed, because the registry is process-wide.
    cli.log.registerSecret("standalone-secret");
    var solo_buf: [256]u8 = undefined;
    var sw = std.Io.Writer.fixed(&solo_buf);
    try cli.log.init("solo").write(&sw, .err, "", "value=standalone-secret and standalone-secret again");
    const solo = sw.buffered();
    try testing.expect(std.mem.indexOf(u8, solo, "standalone-secret") == null);
    // Every occurrence, not just the first.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, solo, cli.log.redaction_mask));

    // Clearing forgets them, so a long-lived process can drop credentials it is done with.
    cli.log.clearSecrets();
    try testing.expectEqual(@as(usize, 0), cli.log.registeredSecretCount());
    var after_buf: [128]u8 = undefined;
    var aw = std.Io.Writer.fixed(&after_buf);
    try cli.log.init("solo").write(&aw, .info, "", "value=standalone-secret");
    try testing.expect(std.mem.indexOf(u8, aw.buffered(), "standalone-secret") != null);
}

// --- The built-in update command ---------------------------------------------

/// A transport that answers from a table, so the update command can be driven without
/// a network. Registered by URL; anything else is a test failure, not a silent miss.
/// One route: a URL and the body it answers with. Named because an anonymous struct
/// type is a different type at every mention, so a table of them cannot be assigned.
const UpdateRoute = struct { url: []const u8, body: []const u8 };

const UpdateStub = struct {
    routes: []const UpdateRoute = &.{},
    calls: usize = 0,
    /// Recorded *during* the call rather than by keeping the slice: the caller owns the
    /// URL and frees it when the fetch returns, so a stored slice would dangle - which is
    /// how the first version of this stub failed its own assertion.
    saw_release_api: bool = false,
    saw_checksum: bool = false,
    saw_binary: bool = false,

    fn fetch(opaque_ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8) anyerror![]u8 {
        const self: *UpdateStub = @ptrCast(@alignCast(opaque_ctx orelse return error.MissingContext));
        self.calls += 1;
        if (std.mem.indexOf(u8, url, "/releases/latest") != null) self.saw_release_api = true;
        if (std.mem.endsWith(u8, url, ".sha256")) self.saw_checksum = true;
        if (std.mem.endsWith(u8, url, "snek-bin")) self.saw_binary = true;
        for (self.routes) |route| {
            if (std.mem.eql(u8, route.url, url)) return allocator.dupe(u8, route.body);
        }
        return error.UnexpectedUrl;
    }

    fn fetcher(self: *UpdateStub) cli.update.Fetcher {
        return .{ .ctx = @ptrCast(self), .fetch = fetch };
    }
};

/// The stub the update command's comptime `fetcher_factory` reaches at run time.
///
/// The metadata is comptime, so the factory must be a function pointer; the routing
/// table it answers from is ordinary runtime state. That split is the whole reason
/// `UpdateMeta` carries a factory rather than a `Fetcher` value.
const UpdateStubState = struct {
    var stub: UpdateStub = .{};

    fn make() cli.update.Fetcher {
        return stub.fetcher();
    }
};

test "the update command: up to date, --check, refusal, install, and a bad checksum" {
    const tmp = "test_update_target.bin";
    const asset_url = "https://example.invalid/snek-bin";
    const checksum_url = asset_url ++ ".sha256";
    const binary_new = "the-new-binary";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp ++ ".old") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp ++ ".new") catch {};

    var url_buf: [cli.update.max_url_len]u8 = undefined;
    const api_url = try cli.update.releaseApiUrl(&url_buf, "93ams", "snek");

    const digest = try cli.update.sha256Hex(testing.allocator, binary_new);
    defer testing.allocator.free(digest);
    const good_checksum = try std.fmt.allocPrint(testing.allocator, "{s}  snek-bin\n", .{digest});
    defer testing.allocator.free(good_checksum);
    const wrong_checksum = try std.fmt.allocPrint(
        testing.allocator,
        "{s}  snek-bin\n",
        .{"0000000000000000000000000000000000000000000000000000000000000000"},
    );
    defer testing.allocator.free(wrong_checksum);

    // Two releases: the version this binary already is, and a newer one.
    const release_same =
        \\{"tag_name":"v0.1.0","assets":[{"name":"snek-bin","size":14,"browser_download_url":"https://example.invalid/snek-bin"}]}
    ;
    const release_newer =
        \\{"tag_name":"v0.9.0","assets":[{"name":"snek-bin","size":14,"browser_download_url":"https://example.invalid/snek-bin"}]}
    ;

    const UpdateCmd = comptime App.updateCommand(.{
        .owner = "93ams",
        .repo = "snek",
        .asset = "snek-bin",
        .current_version = "0.1.0",
        .target_path = tmp,
        .fetcher_factory = UpdateStubState.make,
    });

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();
    var none = [_][]const u8{};

    const readTarget = struct {
        fn read(allocator: std.mem.Allocator) ![]u8 {
            return std.Io.Dir.cwd().readFileAlloc(std.testing.io, tmp, allocator, .limited(256));
        }
    }.read;

    // 1. Nothing to do: the release is not newer, so the body stops *before* the prompt -
    //    which is why this needs neither `--yes` nor a terminal.
    UpdateStubState.stub = .{ .routes = &.{UpdateRoute{ .url = api_url, .body = release_same }} };
    try writeTestFile(tmp, "old-binary");
    try runCmd(App, @TypeOf(UpdateCmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "Already up to date") != null);
    const after_same = try readTarget(testing.allocator);
    defer testing.allocator.free(after_same);
    try testing.expectEqualStrings("old-binary", after_same);

    // The routes for the cases that do have an update available.
    const update_routes = [_]UpdateRoute{
        .{ .url = api_url, .body = release_newer },
        .{ .url = asset_url, .body = binary_new },
        .{ .url = checksum_url, .body = good_checksum },
    };

    // 2. `--check` reports and stops: the binary and its checksum are never fetched.
    UpdateStubState.stub = .{ .routes = &update_routes };
    rig.reset();
    var check_args = [_][]const u8{"--check"};
    try runCmd(App, @TypeOf(UpdateCmd), &check_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "Update available: 0.1.0 -> 0.9.0") != null);
    try testing.expectEqual(@as(usize, 1), UpdateStubState.stub.calls);
    try testing.expect(UpdateStubState.stub.saw_release_api);
    try testing.expect(!UpdateStubState.stub.saw_binary);
    const after_check = try readTarget(testing.allocator);
    defer testing.allocator.free(after_check);
    try testing.expectEqualStrings("old-binary", after_check);

    // 3. Without `--yes`, on a stream that is not a terminal, it refuses rather than
    //    assuming consent - and nothing is written.
    rig.reset();
    UpdateStubState.stub = .{ .routes = &update_routes };
    try testing.expectError(
        error.ConfirmationRequired,
        runCmd(App, @TypeOf(UpdateCmd), &none, &rig.out, &rig.err, &rig.env),
    );
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "without --yes") != null);
    const after_refusal = try readTarget(testing.allocator);
    defer testing.allocator.free(after_refusal);
    try testing.expectEqualStrings("old-binary", after_refusal);

    // 4. `--yes` installs: the target is replaced with the verified bytes, and the
    //    checksum and the payload were both fetched from the release.
    rig.reset();
    UpdateStubState.stub = .{ .routes = &update_routes };
    var yes_args = [_][]const u8{"--yes"};
    try runCmd(App, @TypeOf(UpdateCmd), &yes_args, &rig.out, &rig.err, &rig.env);
    const installed = try readTarget(testing.allocator);
    defer testing.allocator.free(installed);
    try testing.expectEqualStrings(binary_new, installed);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "Updated") != null);
    try testing.expectEqual(@as(usize, 3), UpdateStubState.stub.calls);
    try testing.expect(UpdateStubState.stub.saw_release_api);
    try testing.expect(UpdateStubState.stub.saw_checksum);
    try testing.expect(UpdateStubState.stub.saw_binary);

    // 5. A checksum that does not match the payload stops the install before any write.
    //    This is the check that makes a truncated or swapped download a refusal.
    try writeTestFile(tmp, "old-binary");
    UpdateStubState.stub = .{ .routes = &.{
        UpdateRoute{ .url = api_url, .body = release_newer },
        UpdateRoute{ .url = asset_url, .body = binary_new },
        UpdateRoute{ .url = checksum_url, .body = wrong_checksum },
    } };
    rig.reset();
    try testing.expectError(
        error.ChecksumMismatch,
        runCmd(App, @TypeOf(UpdateCmd), &yes_args, &rig.out, &rig.err, &rig.env),
    );
    const after_bad_checksum = try readTarget(testing.allocator);
    defer testing.allocator.free(after_bad_checksum);
    try testing.expectEqualStrings("old-binary", after_bad_checksum);
}

test "a body may take the plain flags type instead of the merged one" {
    // `App.Flags(X)` is `X` merged with the globals. A body that wants only its own
    // fields may name `X` directly, and the framework copies the fields it asked for.
    const Plain = struct { level: u8 = 1 };

    const Cmd = comptime App.command(.{ .name = "plain_flags", .flags = Plain }, struct {
        fn run(ctx: App.Ctx, flags: Plain) !void {
            try ctx.out.print("level={d}", .{flags.level});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "--level", "4", "--yes" };
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    // The global flag is still parsed - it is part of every command's flags - and the
    // body simply does not see it.
    try testing.expectEqualStrings("level=4", rig.stdout());
}

// --- Deprecation, feature gates, error hooks, dry run, REPL ------------------

// --- Structured output, external plugins, HTML docs --------------------------

test "structured output: --output yaml renders the returned value, and json still works" {
    const Row = struct {
        name: []const u8,
        size: u32,
        tags: []const []const u8,
        note: ?[]const u8 = null,
    };

    const Cmd = comptime App.command(.{ .name = "yaml_out" }, struct {
        fn run(ctx: App.Ctx) !Row {
            _ = ctx;
            return .{ .name = "alpha", .size = 3, .tags = &.{ "x", "y" } };
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "--output", "yaml" };
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    const yaml = rig.stdout();
    // A block mapping, with strings quoted so a value that reads as a number stays a
    // string, and a nested sequence indented under its key.
    try testing.expect(std.mem.indexOf(u8, yaml, "name: \"alpha\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "size: 3\n") != null);
    try testing.expect(std.mem.indexOf(u8, yaml, "tags:\n  - \"x\"\n  - \"y\"\n") != null);
    // An absent optional is null rather than omitted, so the shape is stable.
    try testing.expect(std.mem.indexOf(u8, yaml, "note: null\n") != null);

    // The same value as JSON, chosen by the same flag.
    rig.reset();
    var json_args = [_][]const u8{ "--output", "json" };
    try runCmd(App, @TypeOf(Cmd), &json_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "\"name\":\"alpha\"") != null);

    // And the default is still the human table.
    rig.reset();
    var text_args = [_][]const u8{};
    try runCmd(App, @TypeOf(Cmd), &text_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "Field") != null);

    // A description that would break the document is escaped, not injected.
    const Hostile = comptime App.command(.{
        .name = "hostile",
        .description = "a <script> & \"quotes\"",
    }, null);
    rig.reset();
    var html_args = [_][]const u8{ "generate-docs", "html" };
    try runCmd(App, @TypeOf(Hostile), &html_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.startsWith(u8, rig.stdout(), "<!DOCTYPE html>"));
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "&lt;script&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "<script>") == null);
}

test "the HTML reference lists arguments, flags and subcommands" {
    const Flags = struct {
        force: bool = false,
        token: []const u8 = "shhh",
        pub const meta = .{
            .force = .{ .short = 'f', .help = "Force it" },
            .token = .{ .secret = true },
        };
    };
    const Args = struct {
        target: []const u8,
        pub const meta = .{ .target = .{ .help = "What to act on" } };
    };

    const Leaf = comptime App.command(.{
        .name = "leafy",
        .description = "A leaf",
        .flags = Flags,
        .args = Args,
    }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags), args: Args) !void {
            _ = ctx;
            _ = flags;
            _ = args;
        }
    }.run);
    const Hidden = comptime App.command(.{ .name = "secretcmd", .hidden = true }, null);
    const Root = comptime App.command(.{
        .name = "htmlroot",
        .description = "Root",
        .subcommands = .{ Leaf, Hidden },
    }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "generate-docs", "html" };
    try runCmd(App, @TypeOf(Root), &args, &rig.out, &rig.err, &rig.env);
    const html = rig.stdout();

    try testing.expect(std.mem.indexOf(u8, html, "<h1>htmlroot</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<h2>leafy</h2>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "What to act on") != null);
    try testing.expect(std.mem.indexOf(u8, html, "--force, -f") != null);
    // A secret's default is redacted here too.
    try testing.expect(std.mem.indexOf(u8, html, "shhh") == null);
    try testing.expect(std.mem.indexOf(u8, html, cli.log.redaction_mask) != null);
    // A hidden command is private: no generated document names it.
    try testing.expect(std.mem.indexOf(u8, html, "secretcmd") == null);
}

test "external plugin delegation is off unless asked for, and refuses hostile names" {
    // Enabled, with a prefix: the framework looks for `<prefix>-<token>` on PATH. None of
    // these names exist, so the ordinary unknown-command path runs - which is the point:
    // a missing plugin must not turn into a crash or a silent success.
    const PluginApp = cli.App(usize, .{ .plugins = .{ .enabled = true, .prefix = "snek-nonexistent" } });

    const Cmd = comptime PluginApp.command(.{
        .name = "plugroot",
        .subcommands = .{},
    }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();
    var args = [_][]const u8{"nosuchplugin"};

    try testing.expectError(
        error.UnknownCommand,
        runCmd(PluginApp, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env),
    );
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "Unknown command 'nosuchplugin'") != null);

    // A token that names a path is refused before any lookup, so a command line cannot
    // reach an arbitrary program through the delegation path.
    for ([_][]const u8{ "../evil", "dir/evil", "dir\\evil", ".hidden", "C:evil" }) |hostile| {
        rig.reset();
        var hostile_args = [_][]const u8{hostile};
        try testing.expectError(
            error.UnknownCommand,
            runCmd(PluginApp, @TypeOf(Cmd), &hostile_args, &rig.out, &rig.err, &rig.env),
        );
        // Refused *because* of the name, not because the lookup happened to miss: nothing
        // was executed, so the only output is the unknown-command message.
        try testing.expect(std.mem.indexOf(u8, rig.stdout(), hostile) == null);
    }

    // A dash-prefixed token is a flag, never a subcommand, so it cannot reach the
    // delegation path at all - it is rejected as a flag of a command with no body. That
    // is the property worth pinning: the path check inside the plugin runner is the
    // second line of defence, not the first.
    rig.reset();
    var flag_like = [_][]const u8{"-rf"};
    try testing.expectError(
        error.CommandNotExecutable,
        runCmd(PluginApp, @TypeOf(Cmd), &flag_like, &rig.out, &rig.err, &rig.env),
    );

    // And with delegation off - the default - the same token is simply unknown. This is
    // the configuration every app gets unless it opts in.
    var rig_off: Rig = .{};
    rig_off.init();
    defer rig_off.deinit();
    try testing.expectError(
        error.UnknownCommand,
        runCmd(App, @TypeOf(Cmd), &args, &rig_off.out, &rig_off.err, &rig_off.env),
    );
}

test "a deprecated command warns on use and is not advertised" {
    const Old = comptime App.command(.{
        .name = "old",
        .description = "The old way",
        .deprecated = "use 'new' instead",
    }, struct {
        fn run(ctx: App.Ctx) !void {
            try ctx.out.writeAll("old ran");
        }
    }.run);
    const New = comptime App.command(.{ .name = "new", .description = "The new way" }, null);
    const Root = comptime App.command(.{
        .name = "deproot",
        .subcommands = .{ Old, New },
    }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // It still runs: refusing it would break every script that has not migrated, which
    // is the opposite of what a deprecation is for.
    var args = [_][]const u8{"old"};
    try runCmd(App, @TypeOf(Root), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("old ran", rig.stdout());
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "Command 'old' is deprecated: use 'new' instead") != null);

    // Absent from help ...
    rig.reset();
    var help_args = [_][]const u8{"--help"};
    try runCmd(App, @TypeOf(Root), &help_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "new") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "old") == null);

    // ... from completions ...
    rig.reset();
    var comp_args = [_][]const u8{"__complete"};
    try runCmd(App, @TypeOf(Root), &comp_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "old") == null);

    // ... and from typo suggestions, which are an advertisement too.
    rig.reset();
    var typo_args = [_][]const u8{"odl"};
    try testing.expectError(error.UnknownCommand, runCmd(App, @TypeOf(Root), &typo_args, &rig.out, &rig.err, &rig.env));
    try testing.expect(std.mem.indexOf(u8, rig.stderr(), "Did you mean") == null);
}

test "a feature gate hides a command until its variable is set" {
    const Experimental = comptime App.command(.{
        .name = "beta",
        .description = "An experiment",
        .feature = "SNEK_TEST_EXPERIMENTAL",
    }, struct {
        fn run(ctx: App.Ctx) !void {
            try ctx.out.writeAll("beta ran");
        }
    }.run);
    const Root = comptime App.command(.{
        .name = "featroot",
        .subcommands = .{Experimental},
    }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // Closed: the command does not exist. Not "is hidden" - it is unroutable.
    var args = [_][]const u8{"beta"};
    try testing.expectError(error.UnknownCommand, runCmd(App, @TypeOf(Root), &args, &rig.out, &rig.err, &rig.env));

    // Closed: not advertised either.
    rig.reset();
    var help_args = [_][]const u8{"--help"};
    try runCmd(App, @TypeOf(Root), &help_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "beta") == null);

    // Open: routable and advertised.
    try rig.env.put("SNEK_TEST_EXPERIMENTAL", "1");
    rig.reset();
    try runCmd(App, @TypeOf(Root), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("beta ran", rig.stdout());

    rig.reset();
    try runCmd(App, @TypeOf(Root), &help_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "beta") != null);

    // `0` and `false` are the spellings people use for "off".
    for ([_][]const u8{ "0", "false" }) |off| {
        try rig.env.put("SNEK_TEST_EXPERIMENTAL", off);
        rig.reset();
        try testing.expectError(error.UnknownCommand, runCmd(App, @TypeOf(Root), &args, &rig.out, &rig.err, &rig.env));
    }
}

test "a feature gate hides a flag, including from the environment and a config file" {
    const Gated = struct {
        stable: bool = false,
        shiny: []const u8 = "off",
        pub const meta = .{
            .shiny = .{ .feature = "SNEK_TEST_SHINY", .env = "SNEK_TEST_SHINY_VALUE" },
        };
    };

    const Cmd = comptime App.command(.{ .name = "gated", .flags = Gated }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Gated)) !void {
            try ctx.out.print("{s}", .{flags.shiny});
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // Closed: the flag is unknown, exactly as if it had never been declared.
    var args = [_][]const u8{ "--shiny", "on" };
    try testing.expectError(error.UnknownFlag, runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env));

    // Closed: the environment binding does not fire either, so an experimental flag
    // cannot be switched on by an unrelated variable being present.
    try rig.env.put("SNEK_TEST_SHINY_VALUE", "from-env");
    rig.reset();
    var none = [_][]const u8{};
    try runCmd(App, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("off", rig.stdout());

    // Closed: not in help.
    rig.reset();
    var help_args = [_][]const u8{"--help"};
    try runCmd(App, @TypeOf(Cmd), &help_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "--shiny") == null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "--stable") != null);

    // Open: all three.
    try rig.env.put("SNEK_TEST_SHINY", "yes");
    rig.reset();
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("on", rig.stdout());

    rig.reset();
    try runCmd(App, @TypeOf(Cmd), &help_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "--shiny") != null);

    rig.reset();
    try runCmd(App, @TypeOf(Cmd), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("from-env", rig.stdout());
}

test "an on_error hook sees a failed body and not a successful one" {
    const seen = struct {
        var count: usize = 0;
        var last: []const u8 = "";

        fn report(ctx: App.Ctx, err: anyerror) void {
            _ = ctx;
            count += 1;
            last = @errorName(err);
        }
    };

    const Failing = comptime App.command(.{
        .name = "failing",
        .on_error = seen.report,
    }, struct {
        fn run(ctx: App.Ctx) !void {
            try ctx.out.writeAll("trying");
            return error.SomethingBroke;
        }
    }.run);

    const Fine = comptime App.command(.{
        .name = "fine",
        .on_error = seen.report,
    }, struct {
        fn run(ctx: App.Ctx) !void {
            try ctx.out.writeAll("fine");
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();
    var none = [_][]const u8{};

    seen.count = 0;
    seen.last = "";
    try testing.expectError(error.SomethingBroke, runCmd(App, @TypeOf(Failing), &none, &rig.out, &rig.err, &rig.env));
    try testing.expectEqual(@as(usize, 1), seen.count);
    try testing.expectEqualStrings("SomethingBroke", seen.last);

    // A success is not an error, so the hook stays quiet - and the error still reaches
    // the caller, because the hook reports rather than handles.
    rig.reset();
    try runCmd(App, @TypeOf(Fine), &none, &rig.out, &rig.err, &rig.env);
    try testing.expectEqual(@as(usize, 1), seen.count);
    try testing.expectEqualStrings("fine", rig.stdout());
}

test "meta.dry_run adds --dry-run and puts the state on the context" {
    const Cmd = comptime App.command(.{
        .name = "mutator",
        .dry_run = true,
    }, struct {
        fn run(ctx: App.Ctx) !void {
            try ctx.out.print("dry_run={}", .{ctx.dry_run});
            if (ctx.dry_run) return;
            try ctx.out.writeAll(" (mutating)");
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    // Without the flag the body may mutate.
    var args = [_][]const u8{};
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("dry_run=false (mutating)", rig.stdout());

    // With it, the state travels on the context - so business logic that only receives a
    // `Ctx` can honour it without every layer forwarding a boolean.
    rig.reset();
    var dry = [_][]const u8{"--dry-run"};
    try runCmd(App, @TypeOf(Cmd), &dry, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("dry_run=true", rig.stdout());

    // The generated flag is documented like any other.
    rig.reset();
    var help_args = [_][]const u8{"--help"};
    try runCmd(App, @TypeOf(Cmd), &help_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "--dry-run") != null);
}

test "a command's own dry_run flag reaches the context too" {
    // The older spelling: the field is the author's, and the framework propagates it
    // without adding a second one.
    const Flags = struct { dry_run: bool = false, path: []const u8 = "" };

    const Cmd = comptime App.command(.{ .name = "own_dry", .flags = Flags }, struct {
        fn run(ctx: App.Ctx, flags: App.Flags(Flags)) !void {
            try ctx.out.print("ctx={} flag={}", .{ ctx.dry_run, flags.dry_run });
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{"--dry-run"};
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("ctx=true flag=true", rig.stdout());
}

test "a REPL command with no arguments enters its shell on a terminal, and prints usage otherwise" {
    const Cmd = comptime App.command(.{
        .name = "shellish",
        .description = "A shell",
        .is_repl = true,
    }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();
    var none = [_][]const u8{};

    // Not a terminal: usage, so a script that runs the binary with no arguments does not
    // block on a prompt nobody can answer.
    try runCmdInput(App, @TypeOf(Cmd), &none, .{ .is_tty = false }, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "Usage: shellish") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "Entering interactive shell") == null);

    // A terminal: the shell. `runShell` announces itself before touching raw mode, which
    // is what makes this observable without a real console - the mode setup itself fails
    // under a test runner, and that failure is not the subject here.
    rig.reset();
    runCmdInput(App, @TypeOf(Cmd), &none, .{ .is_tty = true }, &rig.out, &rig.err, &rig.env) catch {};
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "Entering interactive shell for shellish") != null);
}

test "CI disables colour, cursor movement and prompts, and FORCE_COLOR still wins" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    // A terminal everywhere, so the only variable is CI.
    const terminal = cli.render.capability.decide(&env, true, true);
    try testing.expect(terminal.color);
    try testing.expect(terminal.cursor);
    try testing.expect(terminal.interactive);
    try testing.expect(!App.isCiEnvironment(&env));

    try env.put("CI", "true");
    try testing.expect(App.isCiEnvironment(&env));
    const in_ci = cli.render.capability.decide(&env, true, true);
    try testing.expect(!in_ci.color);
    try testing.expect(!in_ci.cursor);
    try testing.expect(!in_ci.interactive);

    // An explicit opt-in for a log that can render escapes.
    try env.put("FORCE_COLOR", "1");
    const forced = cli.render.capability.decide(&env, true, true);
    try testing.expect(forced.color);
    // ... which does not re-enable prompts: a colour preference is not a human present.
    try testing.expect(!forced.interactive);

    // `CI=false` is a thing people write, and it means off.
    try env.put("CI", "false");
    try testing.expect(!App.isCiEnvironment(&env));
    try env.put("CI", "0");
    try testing.expect(!App.isCiEnvironment(&env));
}

test "the documentation generators mark deprecated and gated commands" {
    // The generators have no `Ctx`, so they cannot evaluate a gate the way routing does.
    // They describe the whole surface and say which parts are conditional.
    const Old = comptime App.command(.{
        .name = "oldie",
        .description = "Old",
        .deprecated = "use newie",
    }, null);
    const Beta = comptime App.command(.{
        .name = "betacmd",
        .description = "Beta",
        .feature = "SNEK_TEST_GATE",
    }, null);
    const Root = comptime App.command(.{
        .name = "docs_root",
        .subcommands = .{ Old, Beta },
    }, null);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{ "generate-docs", "markdown" };
    try runCmd(App, @TypeOf(Root), &args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "(deprecated: use newie)") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "(experimental: set SNEK_TEST_GATE)") != null);

    rig.reset();
    var man_args = [_][]const u8{ "generate-docs", "man" };
    try runCmd(App, @TypeOf(Root), &man_args, &rig.out, &rig.err, &rig.env);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "(deprecated: use newie)") != null);
    try testing.expect(std.mem.indexOf(u8, rig.stdout(), "(experimental: set SNEK_TEST_GATE)") != null);
}

test "the shutdown helpers read the signal the handler recorded" {
    cli.platform.signal.reset();
    defer cli.platform.signal.reset();

    try testing.expect(cli.platform.signal.received() == null);
    try testing.expect(!App.isShuttingDown());

    // Installing is what an app with `Config.install_signal_handlers` opts into, and it
    // is exercised here rather than only inside the branch that configuration takes.
    const SigApp = cli.App(usize, .{ .install_signal_handlers = true });
    const installed = SigApp.installSignalHandlers();
    if (comptime @import("builtin").os.tag == .windows) {
        try testing.expectEqual(@as(usize, 2), installed);
    } else {
        try testing.expect(installed >= 2);
    }

    cli.platform.signal.record(.terminate);
    try testing.expectEqual(@as(?cli.platform.signal.Signal, .terminate), App.shutdownSignal());
    try testing.expect(App.isShuttingDown());

    // And a command can poll it: this one returns early, the way a long-running
    // command cleans up on the normal path rather than inside a signal handler.
    const Cmd = comptime App.command(.{ .name = "polling" }, struct {
        fn run(ctx: App.Ctx) !void {
            if (App.isShuttingDown()) {
                try ctx.out.writeAll("stopping");
                return;
            }
            try ctx.out.writeAll("running");
        }
    }.run);

    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    var args = [_][]const u8{};
    try runCmd(App, @TypeOf(Cmd), &args, &rig.out, &rig.err, &rig.env);
    try testing.expectEqualStrings("stopping", rig.stdout());
}

test "exit codes cover the framework's declared error set" {
    // Every member is mapped deliberately: a member that fell through to the
    // `else => 1` arm without anyone deciding that would be an exit status nobody
    // chose, and two members were added by the routing and flag work.
    try testing.expectEqual(@as(u8, 127), App.getExitCode(error.UnknownCommand));
    try testing.expectEqual(@as(u8, 126), App.getExitCode(error.CommandNotExecutable));
    try testing.expectEqual(@as(u8, 130), App.getExitCode(error.UserCancelled));
    try testing.expectEqual(@as(u8, 130), App.getExitCode(error.PromptCancelled));

    for ([_]anyerror{
        error.MissingRequiredFlag,
        error.MissingRequiredPositionalArgument,
        error.MissingFlagValue,
        error.UnknownFlag,
        error.ConflictingFlags,
        error.DependentFlagMissing,
        error.InvalidFlagValue,
        error.ValidationFailed,
        error.TooManyPositionalArguments,
        error.UnknownField,
        error.InvalidFormat,
        error.CommandNestingTooDeep,
    }) |err| {
        try testing.expectEqual(@as(u8, 2), App.getExitCode(err));
    }

    try testing.expectEqual(@as(u8, 2), App.getExitCode(error.HandledError));
    // Not a usage failure and not a success: a refused safeguard is an ordinary failure,
    // which is the safest status for "I did not do what you asked".
    try testing.expectEqual(@as(u8, 1), App.getExitCode(error.ConfirmationRequired));
    try testing.expectEqual(@as(u8, 1), App.getExitCode(error.OutOfMemory));

    // And the entry point's decision: every failure exits with that status, and only the
    // ones that have *not* already been reported get another line of output. This is the
    // part of `App.run` a unit test can reach, since `App.run` terminates the process -
    // and it is the part that was wrong: the binaries returned 1 for everything, and a
    // bad flag value exited 0.
    const reported = [_]anyerror{ error.UnknownCommand, error.UnknownFlag, error.MissingFlagValue, error.OutOfMemory };
    for (reported) |err| {
        const disposition = App.failureDisposition(err);
        try testing.expectEqual(App.getExitCode(err), disposition.code);
        try testing.expect(disposition.report);
    }

    const silent = [_]anyerror{ error.HandledError, error.UserCancelled, error.PromptCancelled };
    for (silent) |err| {
        const disposition = App.failureDisposition(err);
        try testing.expectEqual(App.getExitCode(err), disposition.code);
        try testing.expect(!disposition.report);
    }

    // Concretely: a command line that was wrong is a usage failure, a cancelled prompt is
    // what a shell reports for an interrupt, and neither prints "Error: <name>".
    try testing.expectEqual(@as(u8, 2), App.failureDisposition(error.HandledError).code);
    try testing.expectEqual(@as(u8, 130), App.failureDisposition(error.UserCancelled).code);
    try testing.expectEqual(@as(u8, 127), App.failureDisposition(error.UnknownCommand).code);

    // A caller-supplied map still wins, which is the only way a domain error gets a
    // meaningful status without the framework knowing what it means.
    const Mapped = cli.App(usize, .{ .exit_map = &.{.{ .name = "MyDomainFailure", .code = 77 }} });
    try testing.expectEqual(@as(u8, 77), Mapped.getExitCode(error.MyDomainFailure));
    try testing.expectEqual(@as(u8, 77), Mapped.failureDisposition(error.MyDomainFailure).code);
    try testing.expect(Mapped.failureDisposition(error.MyDomainFailure).report);

    // The declared set is the one the mapping above covers, member for member:
    // 19 named failures plus the `Count` marker.
    const declared = @typeInfo(cli.AppError).error_set.error_names.?;
    try testing.expectEqual(@as(usize, 20), declared.len);
}

test "the public writers that nothing else calls still instantiate" {
    // A generic function's body is analysed only when instantiated, so a `pub fn` that nothing
    // calls is checked by **no** gate - not `zig build`, not the suite, not the Linux compile
    // step. `prompt.select` and `prompt.multiSelect` sat broken in exactly that state through
    // the 0.17 migration: both still used `Enum.fields`, which 0.17 removed, and the build was
    // silent about it.
    //
    // These five are the remaining public writers in that position. Instantiating them here is
    // what makes the compiler look at them; the assertions are deliberately loose, because the
    // property being protected is "it compiles and runs", not any particular byte of output.
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    cli.panic.renderStructuredPanic(&w, "boom", null, .{});
    try testing.expect(w.buffered().len > 0);

    var vars = [_]cli.systemd_exporter.EnvVar{.{ .key = "A", .value = "b" }};
    try cli.systemd_exporter.exportSystemdService(&w, "svc", "desc", "/bin/true", &vars);

    try cli.layout.split(&w, "a\n", "b\n", .{});

    const lg = cli.log.init("svc");
    try lg.writeAt(&w, .info, "scope", "message", null);

    const lineage = cli.config_lineage.init(testing.allocator);
    try lineage.inspect(&w, "path", "1", "u8");
}
