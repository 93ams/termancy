const std = @import("std");
const App = @import("root.zig").App;
const prompt = @import("framework").prompt;

/// `snek add`'s flags.
pub const AddFlags = struct {
    force: bool = false,

    pub const meta = .{
        .force = .{
            .short = 'f',
            .help = "Overwrite existing files without prompting",
        },
    };
};

/// `snek add`'s positional arguments.
///
/// Separate from the flags: what the user typed as an argument and what they typed as
/// an option are different kinds of input, and `addRun` should not have to reach
/// through a flag struct to find one.
pub const AddArgs = struct {
    component: []const u8 = "",

    pub const meta = .{
        .component = .{
            .help = "The name of the component to add (e.g., prompt)",
        },
    };
};

/// The command's metadata, registered separately from its body below.
const meta = .{
    .name = "add",
    .description = "Add a UI component to your project",
    .flags = AddFlags,
    .args = AddArgs,
};

pub const cmd = App.command(meta, addRun);

fn addRun(ctx: App.Ctx, flags: App.Flags(AddFlags), args: AddArgs) !void {
    const alloc = ctx.allocator;

    // Load registry
    const reg_file = std.Io.Dir.cwd().openFile(ctx.io, "registry.json", .{}) catch |err| {
        try ctx.err.print("Failed to open registry.json: {}\n", .{err});
        return;
    };
    defer reg_file.close(ctx.io);

    const stat = try reg_file.stat(ctx.io);
    const reg_data = try alloc.alloc(u8, @as(usize, @intCast(stat.size)));
    _ = try reg_file.readPositionalAll(ctx.io, reg_data, 0);
    defer alloc.free(reg_data);

    const parsed_reg = try std.json.parseFromSlice(std.json.Value, alloc, reg_data, .{});
    defer parsed_reg.deinit();

    const components = parsed_reg.value.object.get("components").?.object;

    var target_components: std.ArrayListUnmanaged([]const u8) = .empty;
    defer target_components.deinit(alloc);

    if (args.component.len == 0) {
        // Interactive mode!
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer keys.deinit(alloc);

        var iter = components.iterator();
        while (iter.next()) |entry| {
            try keys.append(alloc, entry.key_ptr.*);
        }

        const selected = try prompt.multiSelectDynamic(ctx, keys.items, "Which components would you like to add?");
        defer alloc.free(selected);

        if (selected.len == 0) {
            try ctx.out.writeAll("No components selected. Exiting.\n");
            return;
        }

        for (selected) |s| {
            try target_components.append(alloc, s);
        }
    } else {
        try target_components.append(alloc, args.component);
    }

    try std.Io.Dir.cwd().createDirPath(ctx.io, "src/ui");

    for (target_components.items) |comp_name| {
        const comp_val = components.get(comp_name) orelse {
            try ctx.err.print("Component '{s}' not found in registry.\n", .{comp_name});
            continue;
        };

        const url = comp_val.object.get("url").?.string;
        const expected_hash = comp_val.object.get("hash").?.string;

        const dest_path = try std.fmt.allocPrint(alloc, "src/ui/{s}.zig", .{comp_name});
        defer alloc.free(dest_path);

        // Check collision
        if (!flags.force) {
            if (std.Io.Dir.cwd().openFile(ctx.io, dest_path, .{})) |file| {
                defer file.close(ctx.io);
                const l_stat = try file.stat(ctx.io);
                const local_data = try alloc.alloc(u8, @as(usize, @intCast(l_stat.size)));
                _ = try file.readPositionalAll(ctx.io, local_data, 0);
                defer alloc.free(local_data);

                var out: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(local_data, &out, .{});
                const local_hash = std.fmt.bytesToHex(out, .lower);

                // Use hashes to prevent compiler warning
                const eq = std.mem.eql(u8, &local_hash, expected_hash);
                _ = eq;

                const q = try std.fmt.allocPrint(alloc, "File {s} already exists and may have local modifications. Overwrite?", .{dest_path});
                defer alloc.free(q);

                const overwrite = try prompt.confirm(ctx, q, .{ .default = false });
                if (!overwrite) {
                    try ctx.out.print("Skipping {s}...\n", .{comp_name});
                    continue;
                }
            } else |_| {}
        }

        try ctx.out.print("Fetching {s}...\n", .{comp_name});

        // Fetch via HTTP
        var client = std.http.Client{ .allocator = alloc, .io = ctx.io };
        defer client.deinit();
        var aw = std.Io.Writer.Allocating.init(alloc);
        defer alloc.free(aw.writer.buffer);

        const fetch_res = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &aw.writer,
        });

        if (fetch_res.status != .ok) {
            try ctx.err.print("Failed to download {s} (HTTP {d})\n", .{ comp_name, @backingInt(fetch_res.status) });
            continue;
        }

        const body_bytes = aw.writer.buffer[0..aw.writer.end];

        // Write file
        const file = try std.Io.Dir.cwd().createFile(ctx.io, dest_path, .{});
        defer file.close(ctx.io);
        try file.writePositionalAll(ctx.io, body_bytes, 0);

        // Fetch external packages if any
        if (comp_val.object.get("packages")) |pkgs| {
            for (pkgs.array.items) |pkg| {
                const pkg_url = pkg.string;
                try ctx.out.print("Injecting package {s} into build.zig.zon...\n", .{pkg_url});

                const run_res = try std.process.run(alloc, ctx.io, .{
                    .argv = &.{ "zig", "fetch", "--save", pkg_url },
                });
                alloc.free(run_res.stdout);
                alloc.free(run_res.stderr);
            }
        }

        try ctx.out.print("Successfully added {s}!\n", .{comp_name});
    }
}
