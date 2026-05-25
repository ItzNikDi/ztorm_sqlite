const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ztorm_dep = b.dependency("ztorm", .{
        .target = target,
        .optimize = optimize,
    });
    const ztorm_mod = ztorm_dep.module("ztorm");

    const mod = b.addModule("ztorm_sqlite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "ztorm",
                .module = ztorm_mod,
            },
        },
        .link_libc = true,
    });

    mod.linkSystemLibrary("sqlite3", .{});
}
