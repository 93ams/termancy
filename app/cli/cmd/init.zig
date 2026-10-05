const std = @import("std");
const App = @import("root.zig").App;

/// The command's metadata, kept out of the body it describes.
const meta = .{
    .name = "init",
    .description = "Scaffold a new CLI project",
};

pub const cmd = App.command(meta, initRun);

/// No flags, so the body takes the context alone.
fn initRun(ctx: App.Ctx) !void {
    try ctx.out.writeAll("Scaffolding Tigershark CLI project...\n");

    try std.Io.Dir.cwd().createDirPath(ctx.io, "src/ui");

    const components_json =
        \\{
        \\  "version": "0.1.0",
        \\  "components": {}
        \\}
    ;

    // Create components.json if it doesn't exist
    if (std.Io.Dir.cwd().statFile(ctx.io, "components.json", .{})) |_| {
        // Exists, skip
    } else |_| {
        const cfile = try std.Io.Dir.cwd().createFile(ctx.io, "components.json", .{});
        defer cfile.close(ctx.io);
        try cfile.writePositionalAll(ctx.io, components_json, 0);
    }

    if (std.Io.Dir.cwd().statFile(ctx.io, "build.zig", .{})) |_| {
        try ctx.out.writeAll("\nDetected existing project. Scaffolded src/ui/ and components.json.\n");
        try ctx.out.writeAll("Please ensure your build.zig includes the src/ui directory if you use modules.\n");
        return;
    } else |_| {}

    // Create build.zig
    const build_zig =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    const exe = b.addExecutable(.{
        \\        .name = "mycli",
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
        \\    b.installArtifact(exe);
        \\}
    ;

    const build_file = try std.Io.Dir.cwd().createFile(ctx.io, "build.zig", .{});
    defer build_file.close(ctx.io);
    try build_file.writePositionalAll(ctx.io, build_zig, 0);

    // Create main.zig stub
    const main_zig =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    std.debug.print("Welcome to your new Tigershark CLI!\n", .{});
        \\}
    ;

    const main_file = try std.Io.Dir.cwd().createFile(ctx.io, "src/main.zig", .{});
    defer main_file.close(ctx.io);
    try main_file.writePositionalAll(ctx.io, main_zig, 0);

    try ctx.out.writeAll("Success! Created build.zig and src/main.zig.\n");
}
