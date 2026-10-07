//! Hot-reloading a dynamic library, for the platforms that can.
//!
//! This file **is** the type: the file's own scope is the struct, so a consumer
//! writes `const DynLibReloader = @import("dynlib_reloader.zig");`. See the
//! file-layout rule in `.agents/AGENTS.md`.
//!
//! ## Platform support
//!
//! `std.DynLib` has an ELF backend (Linux) and a Mach-O one (macOS) and **no
//! Windows backend** - it is `@compileError("unsupported platform")` there. This
//! type therefore declares `Supported` and compiles everywhere, doing nothing on
//! Windows rather than failing the build.
//!
//! That matters beyond this file: `src/lib/platform/root.zig` applies
//! `refAllDecls`, which is what makes a folder root a compile-time gate. A file
//! that only compiles on one OS turns that gate into a platform-specific build
//! break, so the guard belongs here.
//!
//! Two latent faults are recorded because both were real:
//!   * `std.DynLib.close` takes a pointer, so the call sites use `&lib` rather
//!     than `l.close()` on an optional payload.
//!   * The previous body called `l.close()`, which would not have compiled even
//!     on Linux - and nothing had ever compiled it.

const std = @import("std");
const builtin = @import("builtin");

const Self = @This();

/// `std.DynLib` exists on these targets. Windows is the only one this repository
/// ships that lacks a backend.
pub const Supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

/// The backing handle, or `void` where there is none. Keeping it `void` (rather
/// than an error union) means the fields and methods below still type-check on
/// unsupported targets and the failure is confined to `loadOrReload`.
const Backing = if (Supported) std.DynLib else void;

lib: ?Backing = null,
path: []const u8,

/// Records the path to load. Loads nothing; call `loadOrReload` for that.
pub fn init(path: []const u8) Self {
    return .{ .path = path };
}

/// Loads the library, or reloads it if it is already open.
///
/// Returns `error.UnsupportedPlatform` on a target where `std.DynLib` has no
/// backend, so a caller can degrade instead of failing the build.
pub fn loadOrReload(self: *Self) !void {
    if (comptime !Supported) return error.UnsupportedPlatform;

    if (self.lib) |*l| {
        std.DynLib.close(l);
        self.lib = null;
    }
    self.lib = try std.DynLib.open(self.path);
}

/// Looks up a symbol, or returns null when nothing is loaded.
pub fn lookup(self: *Self, comptime T: type, symbol: [:0]const u8) ?T {
    if (comptime !Supported) return null;
    if (self.lib) |*l| {
        return l.lookup(T, symbol);
    }
    return null;
}

/// Closes the library if it is open. Safe to call twice, and a no-op when
/// nothing was loaded.
pub fn deinit(self: *Self) void {
    if (comptime !Supported) return;
    if (self.lib) |*l| {
        std.DynLib.close(l);
        self.lib = null;
    }
}

test "init records the path and deinit is safe without a load" {
    var r = Self.init("libnothing.so");
    try std.testing.expectEqualStrings("libnothing.so", r.path);
    try std.testing.expect(r.lib == null);
    r.deinit(); // must not touch an unloaded handle
    try std.testing.expect(r.lib == null);
}

test "lookup returns null before anything is loaded" {
    var r = Self.init("libnothing.so");
    defer r.deinit();
    try std.testing.expect(r.lookup(*const anyopaque, "symbol") == null);
}
