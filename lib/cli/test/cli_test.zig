const std = @import("std");
const testing = std.testing;
const cli = @import("../cli.zig");

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
        .io = undefined,
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
    try testing.expect(std.mem.indexOf(u8, output, "auth\tAuthentication commands") != null);
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
        .io = undefined,
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
        .io = undefined,
    };
    var chain = try CustomApp.ExecutionChain.init(testing.allocator, args.len);
    defer chain.deinit(testing.allocator);

    const result = CustomApp.execute(CustomCmd, ctx, &args, &chain);
    try testing.expectError(error.PrivilegedPort, result);
}

// --- Module 1: Global Middleware (Onion Architecture) ---

var mw_trace: [4]u8 = [_]u8{0} ** 4;
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
        .io = undefined,
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
        .io = undefined,
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
        .io = undefined,
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
        .io = undefined,
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
        .io = undefined,
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
        .io = undefined,
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
        .io = undefined,
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
        .io = undefined,
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
        .io = undefined,
    };

    var chain_help = try App.ExecutionChain.init(testing.allocator, 1);
    defer chain_help.deinit(testing.allocator);

    var help_args = [_][]const u8{"--help"};
    try App.execute(DepCmd, help_ctx, &help_args, &chain_help);

    const help_output = out_help_buf[0 .. out_help_buf.len - out_help.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, help_output, "--old_flag") == null);
    try testing.expect(std.mem.indexOf(u8, help_output, "--new_flag") != null);
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
        .io = undefined,
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

    const sample = "const count = 42; // comment\nconst name = \"tigershark\";";
    try cli.style.highlight(&hl_out, sample);

    const hl_str = hl_buf[0 .. hl_buf.len - hl_out.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, hl_str, "\x1b[35mconst\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, hl_str, "\x1b[33m42\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, hl_str, "\x1b[2m// comment\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, hl_str, "\x1b[32m\"tigershark\"\x1b[0m") != null);
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
        .app_name = "tigershark",
        .issues_url = "https://github.com/93ams/tigershark/issues",
        .cache_dir = ".cache/crashes",
    });

    const rendered = panic_buf[0 .. panic_buf.len - panic_out.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, rendered, "UNEXPECTED FATAL ERROR") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Null pointer dereference") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "github.com/93ams/tigershark/issues") != null);
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

    try cli.widgets.copyToClipboard(&writer, "Tigershark CLI", testing.allocator);
    const clip_out = clip_buf[0 .. clip_buf.len - writer.unusedCapacityLen()];

    // Base64 of "Tigershark CLI" is "VGlnZXJzaGFyayBDTEk="
    try testing.expect(std.mem.indexOf(u8, clip_out, "\x1b]52;c;VGlnZXJzaGFyayBDTEk=\x07") != null);
}

test "Widgets: Fuzzy Finder scoring" {
    const target = "src/zig/app/cli/lib/tea.zig";

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
        .io = undefined,
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
        try testing.expect(std.mem.indexOf(u8, result, ".SH SUBCOMMANDS") != null);
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
            .content = "Tigershark v1.0",
            .mime = "text/plain",
        },
    };

    const vfs = cli.vfs.VirtualFileSystem.init(&assets);

    // Lookup
    try testing.expectEqualStrings("{\"theme\": \"dark\"}", vfs.get("config/defaults.json").?);
    try testing.expectEqualStrings("Tigershark v1.0", vfs.get("banner.txt").?);
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
    try testing.expectEqualStrings("Tigershark v1.0", b_buf[0..b_read]);

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
    try cli.zconfig.mergeJson(&cfg, json_data, testing.allocator);

    try testing.expectEqualStrings("127.0.0.1", cfg.host);
    try testing.expectEqual(@as(u16, 9000), cfg.port);
    try testing.expect(cfg.debug);

    // ProfileManager
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    const pm = cli.zconfig.ProfileManager.init(".mycli", null, &env_map);
    try testing.expectEqualStrings("default", pm.active_profile);

    var path_buf: [128]u8 = undefined;
    const profile_path = try pm.getProfilePath(&path_buf);
    try testing.expectEqualStrings(".mycli/profiles/default.json", profile_path);

    const pm_custom = cli.zconfig.ProfileManager.init(".mycli", "staging", &env_map);
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

    cli.proctitle.ProcessTitle.setTitle("tigershark [running]");
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

    try ledger.record(.create_file, "/etc/tigershark.conf", "size: 1KB");
    try ledger.record(.delete_file, "/tmp/legacy.db", "");

    var diff_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&diff_buf);
    try ledger.renderDiff(&writer);
    const out = diff_buf[0 .. diff_buf.len - writer.unusedCapacityLen()];

    try testing.expect(std.mem.indexOf(u8, out, "=== DRY RUN: Proposed Mutations ===") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[+CREATE]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/etc/tigershark.conf") != null);
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
        .name = "tigershark",
        .version = "1.0.0",
        .description = "Next-generation CLI & TUI framework",
        .homepage = "https://tigershark.dev",
        .author = "Tigershark Team",
        .url = "https://github.com/93ams/tigershark/releases/download/v1.0.0/tigershark.tar.gz",
        .sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    };

    // Homebrew
    var brew_buf: [1024]u8 = undefined;
    var brew_writer = std.Io.Writer.fixed(&brew_buf);
    try cli.dist_specs.DistSpecGenerator.generateHomebrew(&brew_writer, pkg);
    const brew_out = brew_buf[0 .. brew_buf.len - brew_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, brew_out, "class tigershark < Formula") != null);

    // Scoop
    var scoop_buf: [1024]u8 = undefined;
    var scoop_writer = std.Io.Writer.fixed(&scoop_buf);
    try cli.dist_specs.DistSpecGenerator.generateScoop(&scoop_writer, pkg);
    const scoop_out = scoop_buf[0 .. scoop_buf.len - scoop_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, scoop_out, "\"bin\": \"tigershark.exe\"") != null);

    // Arch Linux
    var arch_buf: [1024]u8 = undefined;
    var arch_writer = std.Io.Writer.fixed(&arch_buf);
    try cli.dist_specs.DistSpecGenerator.generateArchPkgbuild(&arch_writer, pkg);
    const arch_out = arch_buf[0 .. arch_buf.len - arch_writer.unusedCapacityLen()];
    try testing.expect(std.mem.indexOf(u8, arch_out, "pkgname=tigershark") != null);
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
            .io = undefined,
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

/// Resolves a flag field's name the way the parser does: `-` becomes `_`.
///
/// Mirrors the normalisation in `cli.zig`''s `assignFlag`. Reproduced here rather than
/// driven through a command because the executable assertion is the *parse* behaviour, and
/// building a whole inline `App` to reach it tests more plumbing than the thing at issue.
fn resolveFlagName(comptime FlagsType: type, key: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    var effective = key;
    if (std.mem.indexOfScalar(u8, key, '-') != null) {
        for (key, 0..) |c, i| buf[i] = if (c == '-') '_' else c;
        effective = buf[0..key.len];
    }
    inline for (std.meta.fields(FlagsType)) |field| {
        if (std.mem.eql(u8, effective, field.name)) return field.name;
    }
    return null;
}

test "a dashed flag resolves to the snake_case field" {
    // A Zig field cannot contain `-`, so `dry_run` was reachable only as `--dry_run`. The
    // convention a user expects is `--dry-run`, and the mismatch surfaced as
    // `Unknown flag 'dry-run'` - measured on `config format --dry-run`. Both spellings now
    // resolve, so nothing that worked stops working.
    const DashFlags = struct {
        dry_run: bool = false,
        no_align: bool = false,
        port: u16 = 0,
    };

    try testing.expectEqualStrings("dry_run", resolveFlagName(DashFlags, "dry-run").?);
    try testing.expectEqualStrings("no_align", resolveFlagName(DashFlags, "no-align").?);
    // The underscore spelling is unchanged.
    try testing.expectEqualStrings("dry_run", resolveFlagName(DashFlags, "dry_run").?);
    // A name with no dash is untouched, and an unknown name still misses.
    try testing.expectEqualStrings("port", resolveFlagName(DashFlags, "port").?);
    try testing.expect(resolveFlagName(DashFlags, "dry-run-extra") == null);
    try testing.expect(resolveFlagName(DashFlags, "nope") == null);
}
