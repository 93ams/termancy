const std = @import("std");

pub const PackageMetadata = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    homepage: []const u8,
    author: []const u8,
    url: []const u8,
    sha256: []const u8,
};

pub const DistSpecGenerator = struct {
    pub fn generateHomebrew(writer: anytype, meta: PackageMetadata) !void {
        try writer.print(
            \\class {s} < Formula
            \\  desc "{s}"
            \\  homepage "{s}"
            \\  url "{s}"
            \\  sha256 "{s}"
            \\  license "MIT"
            \\
            \\  def install
            \\    bin.install "{s}"
            \\  end
            \\end
            \\
        , .{ meta.name, meta.description, meta.homepage, meta.url, meta.sha256, meta.name });
    }

    pub fn generateScoop(writer: anytype, meta: PackageMetadata) !void {
        try writer.print(
            \\{{
            \\  "version": "{s}",
            \\  "description": "{s}",
            \\  "homepage": "{s}",
            \\  "license": "MIT",
            \\  "url": "{s}",
            \\  "hash": "{s}",
            \\  "bin": "{s}.exe"
            \\}}
            \\
        , .{ meta.version, meta.description, meta.homepage, meta.url, meta.sha256, meta.name });
    }

    pub fn generateArchPkgbuild(writer: anytype, meta: PackageMetadata) !void {
        try writer.print(
            \\pkgname={s}
            \\pkgver={s}
            \\pkgrel=1
            \\pkgdesc="{s}"
            \\arch=('x86_64' 'aarch64')
            \\url="{s}"
            \\license=('MIT')
            \\source=("$url")
            \\sha256sums=('{s}')
            \\
        , .{ meta.name, meta.version, meta.description, meta.homepage, meta.sha256 });
    }
};
